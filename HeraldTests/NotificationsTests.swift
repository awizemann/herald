import AppKit
import Foundation
import HeraldKit
import Testing

@testable import Herald

/// Records banners instead of showing them, so the app-side wiring is assertable
/// without `UNUserNotificationCenter` (a real bundle, and a prompt at a human).
private actor RecordingCenter: NewMailNotificationPosting {
    private(set) var posted: [NewMailNotification] = []

    func requestAuthorization() async -> Bool { true }
    func post(_ notification: NewMailNotification) async { posted.append(notification) }
}

/// A `UserDefaults` nobody else shares — never the user's real preferences.
private func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
    UserDefaults(suiteName: name)!
}

@Suite("Dock badge")
struct DockBadgeTests {
    /// Fails on the "just stringify the count" version: zero unread must clear
    /// the badge entirely (an empty label still draws an empty red bubble), and
    /// an unbounded count stretches the tile across the Dock.
    @Test func theBadgeLabelIsEmptyAtZeroAndCappedWhenHuge() {
        #expect(DockBadge.label(for: 0) == nil)
        #expect(DockBadge.label(for: -1) == nil)
        #expect(DockBadge.label(for: 1) == "1")
        #expect(DockBadge.label(for: 999) == "999")
        #expect(DockBadge.label(for: 1_000) == "999+")
    }

    /// Fails if the setting is only consulted when the count changes: switching
    /// the badge off must clear a badge that is already on the Dock.
    @Test @MainActor func turningTheSettingOffClearsTheTile() {
        let tile = NSApplication.shared.dockTile
        let previous = tile.badgeLabel
        defer { tile.badgeLabel = previous }

        DockBadge.apply(count: 7, enabled: true, tile: tile)
        #expect(tile.badgeLabel == "7")
        DockBadge.apply(count: 7, enabled: false, tile: tile)
        #expect(tile.badgeLabel == nil)
    }
}

@Suite("Notification settings")
struct NotificationSettingsTests {
    /// Fails if the absent-key default flips: a fresh install must notify and
    /// badge, and `object(forKey:) as? Bool ?? true` is the only spelling that
    /// distinguishes "never set" from "explicitly off".
    @Test func bothSwitchesDefaultOnAndHonourAnExplicitOff() {
        let defaults = makeDefaults()
        #expect(NotificationSettings.newMailEnabled(in: defaults))
        #expect(NotificationSettings.dockBadgeEnabled(in: defaults))

        defaults.set(false, forKey: NotificationSettings.newMailKey)
        defaults.set(false, forKey: NotificationSettings.dockBadgeKey)
        #expect(NotificationSettings.newMailEnabled(in: defaults) == false)
        #expect(NotificationSettings.dockBadgeEnabled(in: defaults) == false)
    }
}

@MainActor
@Suite("New-mail notification wiring")
struct NewMailWiringTests {
    private static func makeModel(
        store: MailStore,
        center: RecordingCenter,
        defaults: UserDefaults
    ) -> (MailViewModel, AsyncStream<SyncEvent>.Continuation) {
        let api = FakeMailAPIClient()
        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .unbounded)
        let model = MailViewModel(
            accountID: "acct",
            accountLabel: "Test",
            api: api,
            store: store,
            actions: MailActionService(api: api, store: store),
            events: stream,
            markReadDelay: .seconds(3600),
            defaults: defaults,
            notifier: NewMailNotifier(center: center, lookup: store)
        )
        return (model, continuation)
    }

    private static func mailbox(_ id: String) -> Mailbox {
        Mailbox(
            id: id,
            address: "\(id)@example.com",
            addresses: [],
            displayName: id,
            isActive: true,
            accessLevel: .manager,
            createdAt: MailFixtures.epoch,
            updatedAt: MailFixtures.epoch
        )
    }

    private static func seedInbox(_ store: MailStore) async throws {
        try await store.upsertMailboxes([Self.mailbox("mbA")], accountID: "acct")
    }

    /// Fails if the switch is captured when the account graph is built: turning
    /// notifications off in Settings must silence the very next poll, without a
    /// relaunch.
    @Test func theSettingIsHonouredPerPass() async throws {
        let store = try MailStore.inMemory()
        try await Self.seedInbox(store)
        let center = RecordingCenter()
        let defaults = makeDefaults()
        defaults.set(false, forKey: NotificationSettings.newMailKey)
        let (model, events) = Self.makeModel(store: store, center: center, defaults: defaults)
        await model.start()

        let arrival = MailFixtures.message(id: "m1", threadID: "t1")
        try await store.upsertMessages([arrival], accountID: "acct")
        events.yield(.changed(ChangeSet(inserted: ["m1"])))
        events.yield(.finished)
        try await wait("the pass to be consumed") { model.status == .idle }
        #expect(await center.posted.isEmpty)

        // Positive control on the same model: flipping the switch back on makes
        // the NEXT pass speak.
        defaults.set(true, forKey: NotificationSettings.newMailKey)
        let second = MailFixtures.message(id: "m2", threadID: "t2")
        try await store.upsertMessages([second], accountID: "acct")
        events.yield(.changed(ChangeSet(inserted: ["m2"])))
        try await wait("the banner to be posted") { await center.posted.count == 1 }
        #expect(await center.posted.first?.threadID == "t2")
        model.stop()
    }

    /// Fails if a clicked banner only sets the selection: the thread it names may
    /// be outside the scope on screen (another folder picked, a search typed), and
    /// selecting an id the list does not hold shows nothing at all.
    ///
    /// The Drafts folder is in here because it shares the middle column with the
    /// conversation list: leaving `isShowingDrafts` up selects the thread behind a
    /// drafts list that never goes away, so the click appears to do nothing but
    /// change the reading pane.
    @Test func aClickedNotificationResetsTheScopeAndSelectsTheThread() async throws {
        let store = try MailStore.inMemory()
        try await Self.seedInbox(store)
        let arrival = MailFixtures.message(id: "m1", threadID: "t1", subject: "Invoice")
        try await store.upsertMessages([arrival], accountID: "acct")
        try await store.upsertConversations(
            [MailFixtures.conversation(arrival)], accountID: "acct", mailboxID: "mbA", folder: .inbox
        )
        let (model, _) = Self.makeModel(store: store, center: RecordingCenter(), defaults: makeDefaults())
        await model.start()

        // Put the UI as far from the banner's thread as the user can: another
        // folder, and a search that matches nothing.
        model.selection = MailViewModel.FolderSelection(mailboxID: "mbA", folder: .archived)
        model.searchQuery = "zzz"
        model.showDrafts(true)

        await model.revealConversation(threadID: "t1")

        #expect(model.selection == MailViewModel.FolderSelection(mailboxID: nil, folder: .inbox))
        #expect(model.searchQuery.isEmpty)
        #expect(!model.isShowingDrafts)
        #expect(model.selectedThreadID == "t1")
        model.stop()
    }

    /// Seeds one inbox thread for `account` and returns nothing but the ids it
    /// used: `t<suffix>` / `m<suffix>`.
    private static func seedThread(_ store: MailStore, account: Account, suffix: String) async throws {
        try await store.upsertMailboxes([Self.mailbox("mbA")], accountID: account.id)
        let arrival = MailFixtures.message(id: "m\(suffix)", threadID: "t\(suffix)")
        try await store.upsertMessages([arrival], accountID: account.id)
        try await store.upsertConversations(
            [MailFixtures.conversation(arrival)], accountID: account.id, mailboxID: "mbA", folder: .inbox
        )
    }

    private static func account(_ host: String) -> Account {
        Account(origin: URL(string: "https://\(host)")!, clientID: "cid", scopes: [])
    }

    /// Fails if the router reveals on whichever account happens to be selected:
    /// with two accounts signed in, a banner for the BACKGROUND one must bring
    /// its account into the window before selecting the thread — and a thread id
    /// that only exists in the other account must not be selected in this one.
    @Test func aClickedBannerSwitchesToItsOwnAccount() async throws {
        let environment = AppEnvironment(defaults: makeDefaults(), notificationPoster: RecordingCenter())
        let store = try MailStore.inMemory()
        let first = Self.account("a.example.com")
        let second = Self.account("b.example.com")
        try await Self.seedThread(store, account: first, suffix: "1")
        try await Self.seedThread(store, account: second, suffix: "2")
        await environment.install(account: first, api: FakeMailAPIClient(), store: store)
        await environment.install(account: second, api: FakeMailAPIClient(), store: store, select: false)
        #expect(environment.selectedAccountID == first.id)

        await environment.open(NewMailRoute(accountID: second.id, threadID: "t2", messageID: "m2"))

        #expect(environment.selectedAccountID == second.id)
        #expect(environment.graphs[second.id]?.mail.selectedThreadID == "t2")
        // The account that was on screen is untouched — it never held `t2`.
        #expect(environment.graphs[first.id]?.mail.selectedThreadID == nil)
    }

    /// Fails if the badge shows only the selected account: the Dock carries ONE
    /// badge for Herald, so an account syncing behind the window has to count.
    @Test func theBadgeSumsEveryAccount() async throws {
        let defaults = makeDefaults()
        let environment = AppEnvironment(defaults: defaults, notificationPoster: RecordingCenter())
        let store = try MailStore.inMemory()
        let first = Self.account("a.example.com")
        let second = Self.account("b.example.com")
        try await Self.seedThread(store, account: first, suffix: "1")
        try await Self.seedThread(store, account: second, suffix: "2")
        await environment.install(account: first, api: FakeMailAPIClient(), store: store)
        await environment.install(account: second, api: FakeMailAPIClient(), store: store, select: false)

        #expect(environment.totalUnreadCount == 2)
        let tile = NSApplication.shared.dockTile
        let previous = tile.badgeLabel
        defer { tile.badgeLabel = previous }
        environment.applyDockBadge()
        #expect(tile.badgeLabel == "2")
    }

    /// Fails if a route that arrives before the graph exists is dropped: clicking
    /// a banner can LAUNCH Herald, and that click is the one most likely to be
    /// thrown away while the cache is still opening.
    @Test func aRouteArrivingBeforeTheGraphIsReplayed() async throws {
        let environment = AppEnvironment(defaults: makeDefaults(), notificationPoster: RecordingCenter())
        let store = try MailStore.inMemory()
        let account = Self.account("a.example.com")
        try await Self.seedThread(store, account: account, suffix: "1")

        // Clicked while the app is still launching: no view-model exists yet.
        await environment.open(NewMailRoute(accountID: account.id, threadID: "t1", messageID: "m1"))
        #expect(environment.mail == nil)

        await environment.install(account: account, api: FakeMailAPIClient(), store: store)
        #expect(environment.mail?.selectedThreadID == "t1")
    }

    /// Fails if the `[AnyHashable: Any]` payload is force-cast or passed across
    /// actors as-is: the system adds its own non-string entries, and only the
    /// string pairs Herald wrote are Sendable enough to cross.
    @Test nonisolated func theSystemPayloadIsNarrowedToStrings() {
        let userInfo: [AnyHashable: Any] = [
            NewMailNotification.accountIDKey: "acct",
            NewMailNotification.threadIDKey: "t1",
            "systemAdded": 42,
            17: "not a string key",
        ]
        let narrowed = NewMailNotificationRouter.stringUserInfo(userInfo)
        #expect(narrowed == [NewMailNotification.accountIDKey: "acct", NewMailNotification.threadIDKey: "t1"])
        #expect(NewMailNotification.route(from: narrowed)?.threadID == "t1")
    }
}
