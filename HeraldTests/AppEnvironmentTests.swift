import Foundation
import HeraldKit
import Testing
@testable import Herald

@MainActor
@Suite struct AppEnvironmentLifecycleTests {
    private static func account(_ host: String) -> Account {
        Account(origin: URL(string: "https://\(host)")!, clientID: "cid", scopes: [])
    }

    /// Re-authenticating rebuilds the SAME account's graph, and the old code
    /// built the new one on top of the old: the previous `SyncEngine` kept
    /// polling forever and the previous `MailViewModel` kept consuming its
    /// events. Fails if the superseded engine still answers a refresh — the leak
    /// is invisible otherwise, because the new graph works fine either way.
    @Test func reinstallingTheSameAccountStopsTheSupersededGraph() async throws {
        let environment = AppEnvironment(defaults: Self.scratchDefaults())
        let store = try MailStore.inMemory()
        let account = Self.account("a.example.com")
        let first = FakeMailAPIClient()
        let second = FakeMailAPIClient()

        await environment.install(account: account, api: first, store: store)
        let superseded = try #require(environment.mail)
        try await wait("the first client to poll once") { await first.mailboxRequestCount >= 1 }

        await environment.install(account: account, api: second, store: store)
        let leakedBaseline = await first.mailboxRequestCount

        // The superseded view-model still holds the superseded engine. Asking it
        // to refresh must do nothing, because that engine was stopped.
        await superseded.refresh()

        // Positive control on the live graph: it DOES poll again, which also
        // gives the superseded engine the same window in which to misbehave.
        let liveBaseline = await second.mailboxRequestCount
        await environment.mail?.refresh()
        try await wait("the live graph to poll again") { await second.mailboxRequestCount > liveBaseline }

        #expect(
            await first.mailboxRequestCount == leakedBaseline,
            "The superseded SyncEngine kept polling"
        )
        #expect(environment.graphs.count == 1, "Re-auth must not leave two graphs for one account")
        #expect(environment.accountIDs == [account.id], "Re-auth must not duplicate the switcher entry")
    }

    /// The whole point of P1: adding a second account used to tear the first
    /// one's graph down, so the account you were not looking at stopped syncing
    /// and its unread counts froze. Fails if the first account's engine no
    /// longer answers a refresh once a second account is installed.
    @Test func addingASecondAccountKeepsTheFirstEngineSyncing() async throws {
        let environment = AppEnvironment(defaults: Self.scratchDefaults())
        let store = try MailStore.inMemory()
        let firstAPI = FakeMailAPIClient()
        let secondAPI = FakeMailAPIClient()
        let a = Self.account("a.example.com")
        let b = Self.account("b.example.com")

        await environment.install(account: a, api: firstAPI, store: store)
        let backgrounded = try #require(environment.mail)
        try await wait("account A to poll once") { await firstAPI.mailboxRequestCount >= 1 }

        await environment.install(account: b, api: secondAPI, store: store)
        #expect(environment.selectedAccountID == b.id, "Adding an account should show it")
        #expect(environment.accounts.map(\.id) == [a.id, b.id], "Both accounts belong in the switcher")
        #expect(environment.mail?.accountID == b.id)

        let baseline = await firstAPI.mailboxRequestCount
        await backgrounded.refresh()
        try await wait("the unselected account A to keep polling") {
            await firstAPI.mailboxRequestCount > baseline
        }
    }

    /// Sign-out was "sign out of everything": it dropped the whole graph and
    /// purged the cache. Fails if signing one account out stops the other's
    /// engine, drops it from the switcher, or purges its cached rows.
    @Test func signingOutOneAccountLeavesTheOtherRunning() async throws {
        let a = Self.account("a.example.com")
        let b = Self.account("b.example.com")
        let accountStore = InMemoryAccountStore(accounts: [a, b])
        let environment = AppEnvironment(
            auth: AuthCoordinator(store: accountStore),
            defaults: Self.scratchDefaults()
        )
        let store = try MailStore.inMemory()
        let apiA = FakeMailAPIClient()
        let apiB = FakeMailAPIClient()

        _ = try await store.upsertConversations(
            [MailFixtures.conversation(MailFixtures.message(id: "m-a"))],
            accountID: a.id, mailboxID: nil, folder: .inbox
        )
        _ = try await store.upsertConversations(
            [MailFixtures.conversation(MailFixtures.message(id: "m-b"))],
            accountID: b.id, mailboxID: nil, folder: .inbox
        )

        await environment.install(account: a, api: apiA, store: store)
        await environment.install(account: b, api: apiB, store: store)
        let survivor = try #require(environment.graphs[a.id]?.mail)

        await environment.signOut(accountID: b.id)

        #expect(environment.graphs[b.id] == nil)
        #expect(environment.accountIDs == [a.id], "The signed-out account must leave the switcher")
        #expect(environment.selectedAccountID == a.id, "The window must fall back to what is left")
        #expect(environment.phase == .ready, "One account left is not signed out")
        let remaining = try accountStore.accounts().map(\.id)
        #expect(remaining == [a.id])

        // Scoped purge: B's rows are gone, A's — in the same container — are not.
        let purged = try await store.unreadCount(accountID: b.id, mailboxID: nil, folder: .inbox)
        let kept = try await store.unreadCount(accountID: a.id, mailboxID: nil, folder: .inbox)
        #expect(purged == 0)
        #expect(kept == 1)

        // And A's engine is still alive: it answers a refresh.
        let baseline = await apiA.mailboxRequestCount
        await survivor.refresh()
        try await wait("the surviving account to keep polling") {
            await apiA.mailboxRequestCount > baseline
        }
    }

    /// Signing the LAST account out is still a full sign-out.
    @Test func signingOutTheLastAccountReturnsToOnboarding() async throws {
        let a = Self.account("a.example.com")
        let environment = AppEnvironment(
            auth: AuthCoordinator(store: InMemoryAccountStore(accounts: [a])),
            defaults: Self.scratchDefaults()
        )
        await environment.install(account: a, api: FakeMailAPIClient(), store: try MailStore.inMemory())

        await environment.signOut(accountID: a.id)

        #expect(environment.phase == .signedOut)
        #expect(environment.selectedAccountID == nil)
        #expect(environment.mail == nil)
    }

    /// A compose window opened from account A must keep sending through A even
    /// after the user switches the window to B — otherwise the reply lands on
    /// whichever server happened to be selected when Send was pressed. Fails if
    /// the composer is resolved against the CURRENT selection.
    @Test func composeStaysBoundToTheAccountItWasOpenedFrom() async throws {
        let environment = AppEnvironment(defaults: Self.scratchDefaults())
        let store = try MailStore.inMemory()
        let a = Self.account("a.example.com")
        let b = Self.account("b.example.com")
        await environment.install(account: a, api: FakeMailAPIClient(), store: store)

        let id = try #require(await environment.prepareCompose(ComposeRequest(kind: .new)))
        #expect(environment.composeAccountID(for: id) == a.id)

        await environment.install(account: b, api: FakeMailAPIClient(), store: store)
        #expect(environment.selectedAccountID == b.id)

        let model = try #require(environment.makeComposeViewModel(id: id))
        model.bodyText = "Half-written"
        #expect(environment.composeAccountID(for: id) == a.id, "The composer followed the selection")
        #expect(environment.makeComposeViewModel(id: id) === model)

        // Signing A out takes A's composer with it: its OutboxService is gone.
        await environment.signOut(accountID: a.id)
        #expect(environment.composeAccountID(for: id) == nil)
        #expect(environment.makeComposeViewModel(id: id) == nil)
    }

    /// The compose window's `.task(id:)` re-runs whenever SwiftUI rebuilds the
    /// scene root, and the old code CONSUMED the resolved context on the way
    /// through: the second run built nothing, so a half-written message turned
    /// into "this draft is no longer available". Fails if the same request id
    /// stops resolving to the same composer, or if a closed composer is
    /// resurrected instead of released.
    @Test func theSameComposeRequestAlwaysResolvesToTheSameViewModel() async throws {
        let environment = AppEnvironment(defaults: Self.scratchDefaults())
        let store = try MailStore.inMemory()
        await environment.install(
            account: Self.account("a.example.com"),
            api: FakeMailAPIClient(),
            store: store
        )

        let id = try #require(await environment.prepareCompose(ComposeRequest(kind: .new)))
        let first = try #require(environment.makeComposeViewModel(id: id))
        first.bodyText = "Half-written"
        let second = try #require(environment.makeComposeViewModel(id: id))

        #expect(first === second, "Rebuilding the compose window discarded the draft")
        #expect(second.bodyText == "Half-written")

        // Releasing an OPEN composer must not drop it either.
        environment.releaseComposeViewModel(id: id)
        #expect(environment.makeComposeViewModel(id: id) === first)

        // Once it really is closed the window shows "no longer available" rather
        // than a resurrected copy of a sent message.
        first.close()
        environment.releaseComposeViewModel(id: id)
        #expect(environment.makeComposeViewModel(id: id) == nil)
    }

    /// The window must reopen on the account the user was last reading, not on
    /// whichever one the account list happens to yield first. Fails if the pick
    /// is not persisted, or is persisted under a key another instance cannot
    /// read back.
    @Test func theSelectedAccountIsPersisted() async throws {
        let defaults = Self.scratchDefaults()
        let environment = AppEnvironment(defaults: defaults)
        let store = try MailStore.inMemory()
        let a = Self.account("a.example.com")
        let b = Self.account("b.example.com")

        await environment.install(account: a, api: FakeMailAPIClient(), store: store)
        await environment.install(account: b, api: FakeMailAPIClient(), store: store)
        environment.selectedAccountID = a.id

        #expect(defaults.string(forKey: AppEnvironment.selectedAccountKey) == a.id)

        // Signing the last account out must not leave a dangling pick behind for
        // the next launch to restore.
        environment.selectedAccountID = nil
        #expect(defaults.string(forKey: AppEnvironment.selectedAccountKey) == nil)
    }

    /// The badge value future work will read. Fails if it reports only the
    /// selected account — which is what a naive `mail?.unread` would do.
    @Test func aggregateUnreadCountsEveryAccount() async throws {
        let environment = AppEnvironment(defaults: Self.scratchDefaults())
        let store = try MailStore.inMemory()
        let a = Self.account("a.example.com")
        let b = Self.account("b.example.com")

        _ = try await store.upsertConversations(
            [MailFixtures.conversation(MailFixtures.message(id: "m-a1")),
             MailFixtures.conversation(MailFixtures.message(id: "m-a2"))],
            accountID: a.id, mailboxID: nil, folder: .inbox
        )
        _ = try await store.upsertConversations(
            [MailFixtures.conversation(MailFixtures.message(id: "m-b1"))],
            accountID: b.id, mailboxID: nil, folder: .inbox
        )

        await environment.install(account: a, api: FakeMailAPIClient(), store: store)
        await environment.install(account: b, api: FakeMailAPIClient(), store: store)

        #expect(environment.unreadCount(forAccount: a.id) == 2)
        #expect(environment.unreadCount(forAccount: b.id) == 1)
        #expect(environment.totalUnreadCount == 3)
    }

    /// The switcher has to tell two accounts on the same provider apart, and the
    /// default label IS the host. Fails if the host is dropped, or duplicated
    /// when the user never renamed the account.
    @Test func theAccountPickerLabelNamesTheHost() {
        let plain = Self.account("a.example.com")
        #expect(AppEnvironment.accountPickerLabel(for: plain, unread: 0) == "a.example.com")
        #expect(AppEnvironment.accountPickerLabel(for: plain, unread: 4) == "a.example.com (4)")

        var renamed = plain
        renamed.label = "Work"
        #expect(AppEnvironment.accountPickerLabel(for: renamed, unread: 0) == "Work — a.example.com")
    }

    /// A relaunch brings the remaining accounts up BEHIND the window, and they
    /// must not yank it off the account the user was reading. Fails if a
    /// background restore selects itself — while still requiring that a live
    /// graph is selected when the window is showing nothing.
    @Test func aBackgroundRestoreDoesNotStealTheWindow() async throws {
        let environment = AppEnvironment(defaults: Self.scratchDefaults())
        let store = try MailStore.inMemory()
        let a = Self.account("a.example.com")
        let b = Self.account("b.example.com")

        // Nothing showing yet: even an unselected install has to take the window.
        await environment.install(account: a, api: FakeMailAPIClient(), store: store, select: false)
        #expect(environment.selectedAccountID == a.id)

        await environment.install(account: b, api: FakeMailAPIClient(), store: store, select: false)
        #expect(environment.selectedAccountID == a.id, "A background restore stole the window")
        #expect(environment.graphs.count == 2, "…but it still has to be running")
    }

    // MARK: Automatic re-authentication

    /// A dead port: discovery refuses immediately, so the automatic attempt runs
    /// its real path and fails fast without leaving the machine.
    private static func unreachableAccount() -> Account {
        Account(origin: URL(string: "https://127.0.0.1:9")!, clientID: "cid", scopes: [])
    }

    /// Herald's frontmost state, flipped mid-test.
    private final class ActivationFlag: @unchecked Sendable {
        var isActive: Bool
        init(_ isActive: Bool) { self.isActive = isActive }
    }

    /// An API client whose every conversation fetch is a 401, which is what a
    /// dead HQBase web session looks like to the sync engine.
    private static func expiredAPI() async -> FakeMailAPIClient {
        let api = FakeMailAPIClient()
        await api.setListError(.unauthorized)
        return api
    }

    private static func environment(
        account: Account,
        tracker: RecordingUsageTracker,
        flag: ActivationFlag
    ) -> AppEnvironment {
        AppEnvironment(
            auth: AuthCoordinator(store: InMemoryAccountStore(accounts: [account])),
            defaults: scratchDefaults(),
            usage: tracker,
            isApplicationActive: { flag.isActive }
        )
    }

    /// The whole point of the guardrail AND of the deferral behind it: an expired
    /// session discovered while the user is in another app must NOT open a
    /// consent window then — and must not be forgotten either, because that is
    /// when sessions expire. Fails both if Herald signs in behind the user's back
    /// and if coming back to Herald never retries (the feature would then almost
    /// never fire, since the sync pass that finds the expiry usually runs in the
    /// background).
    @Test func anExpirySeenInTheBackgroundIsDeferredUntilHeraldIsFrontmost() async throws {
        let account = Self.unreachableAccount()
        let tracker = RecordingUsageTracker()
        let flag = ActivationFlag(false)
        let environment = Self.environment(account: account, tracker: tracker, flag: flag)
        await environment.install(account: account, api: await Self.expiredAPI(), store: try MailStore.inMemory())

        try await wait("the expired session to reach the banner") {
            environment.graphs[account.id]?.mail.status == .needsReauth
        }
        await environment.drainPendingUsage()
        #expect(await tracker.names.contains("account_reauthenticated") == false, "signed in behind the user's back")
        #expect(environment.isReauthenticating(accountID: account.id) == false)

        // The user comes back to Herald.
        flag.isActive = true
        await environment.setWindowActive(true)

        await environment.drainPendingUsage()
        let reauths = await tracker.events.filter { $0.name == "account_reauthenticated" }
        #expect(reauths.count == 1, "the deferred repair was dropped instead of retried")
        #expect(reauths.first?.props["automatic"] == .bool(true), "an automatic attempt must be labelled one")
        // It failed (the origin is unreachable), so the banner is still the way
        // back in — and nothing of the attempt leaked into the sheet state.
        #expect(environment.isReauthenticating(accountID: account.id) == false)
        #expect(environment.presentsAddAccount == false)
        #expect(environment.signInError == nil, "an automatic failure must stay quiet")
        #expect(environment.isSigningIn == false)
    }

    /// Fails if the cooldown is not wired to the entry point: every activation —
    /// and every failed poll — would otherwise reopen the consent window.
    @Test func aFailedAutomaticAttemptIsNotRepeatedImmediately() async throws {
        let account = Self.unreachableAccount()
        let tracker = RecordingUsageTracker()
        let environment = Self.environment(account: account, tracker: tracker, flag: ActivationFlag(true))
        await environment.install(account: account, api: await Self.expiredAPI(), store: try MailStore.inMemory())

        try await wait("the automatic attempt to run and fail") {
            await environment.drainPendingUsage()
            return await tracker.names.contains("account_reauthenticated")
        }
        await environment.setWindowActive(true)
        await environment.attemptAutomaticReauthentication(accountID: account.id)

        await environment.drainPendingUsage()
        let reauths = await tracker.names.filter { $0 == "account_reauthenticated" }
        #expect(reauths.count == 1, "the cooldown did not suppress the later attempts")
    }

    /// An account syncing BEHIND the window must not sign itself in: the sign-in
    /// selects the account it installs, which would pull the user off the mail
    /// they are reading. Fails if the attempt is not scoped to the selection.
    @Test func aBackgroundAccountDoesNotSignItselfIn() async throws {
        let background = Self.unreachableAccount()
        let front = Self.account("front.example.com")
        let tracker = RecordingUsageTracker()
        let environment = AppEnvironment(
            auth: AuthCoordinator(store: InMemoryAccountStore(accounts: [background, front])),
            defaults: Self.scratchDefaults(),
            usage: tracker,
            isApplicationActive: { true }
        )
        let store = try MailStore.inMemory()
        await environment.install(account: background, api: await Self.expiredAPI(), store: store)
        await environment.install(account: front, api: FakeMailAPIClient(), store: store)
        #expect(environment.selectedAccountID == front.id)

        try await wait("the background account's session to expire") {
            environment.graphs[background.id]?.mail.status == .needsReauth
        }
        await environment.setWindowActive(true)

        await environment.drainPendingUsage()
        #expect(await tracker.names.contains("account_reauthenticated") == false)
        #expect(environment.selectedAccountID == front.id, "a background account stole the window")
    }

    /// Signing out while an automatic attempt is in flight used to be able to
    /// bring the account back: the attempt's `install` lands after the removal
    /// and re-selects it. Fails if the sign-out does not cancel and await the
    /// attempt.
    @Test func signingOutCancelsAnAutomaticAttempt() async throws {
        let account = Self.unreachableAccount()
        let tracker = RecordingUsageTracker()
        let environment = Self.environment(account: account, tracker: tracker, flag: ActivationFlag(true))
        await environment.install(account: account, api: await Self.expiredAPI(), store: try MailStore.inMemory())
        try await wait("the expired session to reach the banner") {
            environment.graphs[account.id]?.mail.status == .needsReauth
        }

        await environment.signOut(accountID: account.id)

        #expect(environment.graphs[account.id] == nil, "the signed-out account came back")
        #expect(environment.accountIDs.isEmpty)
        #expect(environment.isReauthenticating(accountID: account.id) == false)
        #expect(environment.phase == .signedOut)
    }

    /// A throwaway suite, so a test never writes the developer's real pick.
    private static func scratchDefaults() -> UserDefaults {
        let suite = "AppEnvironmentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
