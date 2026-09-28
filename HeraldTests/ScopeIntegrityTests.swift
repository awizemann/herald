import Foundation
import HeraldKit
import Observation
import Synchronization
import Testing
@testable import Herald

/// Audit fixes F1 (2026-09-28): what a scope lists and counts, and whether an
/// answer computed for one scope can land under another.
///
/// Uses ``ScopeHarness``: acme.co (`mbSales`, `mbTeam`), north.io (`mbOps`),
/// one unread inbox thread per mailbox and an archived `t_sales_arch`.
@MainActor
@Suite(.scratchDefaults)
struct ScopeIntegrityTests {
    private static let account = ScopeHarness.account

    private static func addInbox(
        _ harness: ScopeHarness, id: String, thread: String, mailbox: String?, minute: Int
    ) async throws {
        let message = MailFixtures.message(
            id: id, threadID: thread, mailboxID: mailbox,
            date: MailFixtures.epoch.addingTimeInterval(TimeInterval(3_600 + minute * 60))
        )
        try await harness.store.upsertMessages([message], accountID: account)
        try await harness.store.upsertConversations(
            [MailFixtures.conversation(message)], accountID: account, mailboxID: mailbox, folder: .inbox
        )
    }

    // MARK: - Unassigned mail in All domains

    /// A conversation tied to NO mailbox belongs to no domain, so excluding a
    /// domain cannot take it out of All domains. Fails on the old explicit set
    /// (every enabled mailbox minus the excluded ones, no `""`): the row
    /// vanished — from the list, the All domains count and the badge — the
    /// moment any domain was excluded.
    @Test("All domains keeps unassigned rows when a domain is excluded")
    func allDomainsKeepsUnassigned() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        try await Self.addInbox(harness, id: "m_loose", thread: "t_loose", mailbox: nil, minute: 1)
        await harness.model.start()
        #expect(harness.listed.contains("t_loose"), "control: listed with nothing excluded")
        #expect(harness.model.allDomainsInboxUnread == 4)

        DomainPreferences.setIncludeInAll(false, accountID: Self.account, domainID: ScopeHarness.north, in: harness.defaults)
        DomainPreferences.setCountInBadge(false, accountID: Self.account, domainID: ScopeHarness.north, in: harness.defaults)
        await harness.model.domainPreferencesDidChange()

        #expect(harness.listed == ["t_sales", "t_team", "t_loose"])
        #expect(harness.model.allDomainsInboxUnread == 3, "t_sales, t_team and the unassigned t_loose")
        #expect(harness.model.badgeInboxUnread == 3)
        #expect(harness.model.folderUnreadCounts[.inbox] == 3)
        // Still nowhere narrower.
        harness.model.selectScope(harness.acmeScope)
        await harness.settle()
        #expect(!harness.listed.contains("t_loose"))
    }

    // MARK: - One thread, two mailboxes

    /// `t_both` has an unread inbox row in BOTH acme mailboxes. Fails on the
    /// undeduped multi-mailbox fetch (the thread listed twice in the domain
    /// and in All domains) and on the summed counts (acme 4, All domains 5).
    @Test("A thread in two mailboxes is listed and counted once")
    func threadInTwoMailboxesIsOne() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        try await Self.addInbox(harness, id: "m_both_s", thread: "t_both", mailbox: "mbSales", minute: 1)
        try await Self.addInbox(harness, id: "m_both_t", thread: "t_both", mailbox: "mbTeam", minute: 2)
        await harness.model.start()

        let allIDs = harness.model.presentedConversations.map(\.id)
        #expect(allIDs.count == Set(allIDs).count, "no duplicate rows in All domains")
        #expect(allIDs.filter { $0 == "t_both" }.count == 1)
        #expect(harness.model.presentedConversations.first { $0.id == "t_both" }?.latest.id == "m_both_t", "the newest row wins")
        #expect(harness.model.allDomainsInboxUnread == 4)
        #expect(harness.model.badgeInboxUnread == 4)
        #expect(harness.model.inboxUnreadByDomain[ScopeHarness.acme] == 3)
        #expect(harness.model.inboxUnreadByMailbox["mbSales"] == 2, "a mailbox still counts its own row")

        harness.model.selectScope(harness.acmeScope)
        await harness.settle()
        let domainIDs = harness.model.presentedConversations.map(\.id)
        #expect(domainIDs.sorted() == ["t_both", "t_sales", "t_team"])
        #expect(harness.model.folderUnreadCounts[.inbox] == 3)
    }

    // MARK: - Staleness

    /// A count computed for acme must not be published once the window has
    /// moved to north. The seam fires between the store read and the publish;
    /// the navigation lands there. Fails on the old reload (no generation
    /// check): acme's fresh Inbox count (3) was published under north for as
    /// long as north's own reload took.
    @Test("A count reload overtaken by a navigation does not publish")
    func countReloadLosesToNavigation() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()
        harness.model.selectScope(harness.acmeScope)
        await harness.settle()
        #expect(harness.model.folderUnreadCounts[.inbox] == 2)
        // A new acme thread the counts have not seen yet.
        try await Self.addInbox(harness, id: "m_new", thread: "t_new", mailbox: "mbTeam", minute: 1)

        var navigated = false
        harness.model.countsWillPublish = { [model = harness.model] in
            guard !navigated else { return }
            navigated = true
            model.selectScope(.domain(ScopeHarness.north))
        }
        await harness.model.reloadConversations()
        #expect(navigated)
        #expect(harness.model.scope == .domain(ScopeHarness.north))
        #expect(harness.model.folderUnreadCounts[.inbox] != 3, "acme's count never lands under north")

        harness.model.countsWillPublish = nil
        await harness.settle()
        #expect(harness.model.folderUnreadCounts[.inbox] == 1, "north's own reload publishes")
    }

    /// A move to another scope clears the rows at once and says it is loading;
    /// a same-location reload keeps them (no flicker). Fails if the old
    /// scope's rows sit under the new header until the store answers.
    @Test("A scope change clears the old rows until the store answers")
    func scopeChangeClearsRows() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()
        #expect(!harness.model.isLoadingConversations)

        harness.model.selectScope(.domain(ScopeHarness.north))
        #expect(harness.model.presentedConversations.isEmpty, "acme's rows are not shown under north")
        #expect(harness.model.isLoadingConversations)
        await harness.settle()
        #expect(harness.listed == ["t_ops"])
        #expect(!harness.model.isLoadingConversations)

        // Same location: the rows stay while the reload runs.
        let reload = Task { await harness.model.reloadConversations() }
        #expect(harness.listed == ["t_ops"])
        #expect(!harness.model.isLoadingConversations)
        await reload.value
        #expect(harness.listed == ["t_ops"])
    }

    // MARK: - Observed preferences

    /// The list's attribution reads monogram overrides; a reader must be
    /// invalidated when one changes. Fails on the old read straight from
    /// `defaults`, which Observation cannot see — the list kept the old
    /// letters until something unrelated redrew it.
    @Test("A monogram override invalidates the list's attribution")
    func monogramOverrideIsObserved() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()
        let before = harness.model.rowAttributionIndex().attribution(forMailbox: "mbSales").monogram

        let invalidated = Mutex(false)
        withObservationTracking {
            _ = harness.model.rowAttributionIndex()
        } onChange: {
            invalidated.withLock { $0 = true }
        }
        DomainPreferences.setMonogramOverride("ZZ", accountID: Self.account, domainID: ScopeHarness.acme, in: harness.defaults)
        await harness.model.domainPreferencesDidChange()

        #expect(invalidated.withLock { $0 })
        #expect(before != "ZZ")
        #expect(harness.model.rowAttributionIndex().attribution(forMailbox: "mbSales").monogram == "ZZ")
    }

    // MARK: - New message From

    /// With nothing selected, a new message is sent from the scope's first
    /// mailbox, and never from a hidden domain. The mailbox list is sorted by
    /// display name, so `mbOps` (north) is `mailboxes.first` — the old pick
    /// for every scope. Fails on it for the acme scope and for All domains
    /// with north hidden.
    @Test("A new message's From follows the scope and skips hidden domains")
    func newMessageFromFollowsScope() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()
        #expect(harness.model.mailboxes.first?.id == "mbOps", "fixture: north sorts first")

        harness.model.selectScope(harness.acmeScope)
        await harness.settle()
        let inAcme = try #require(await harness.model.composeContext(for: ComposeRequest(kind: .new)))
        #expect(inAcme.mailboxID == "mbSales")
        #expect(inAcme.fromAddress == "sales@acme.co")

        harness.model.selectAllDomains()
        await harness.settle()
        DomainPreferences.setHidden(true, accountID: Self.account, domainID: ScopeHarness.north, in: harness.defaults)
        await harness.model.domainPreferencesDidChange()
        let inAll = try #require(await harness.model.composeContext(for: ComposeRequest(kind: .new)))
        #expect(inAll.mailboxID == "mbSales", "never the hidden north's mbOps")

        // Every domain hidden: no From rather than a hidden one.
        DomainPreferences.setHidden(true, accountID: Self.account, domainID: ScopeHarness.acme, in: harness.defaults)
        await harness.model.domainPreferencesDidChange()
        let nowhere = try #require(await harness.model.composeContext(for: ComposeRequest(kind: .new)))
        #expect(nowhere.mailboxID == nil)
        #expect(nowhere.fromAddress.isEmpty)
    }
}

/// Audit fix F1 #9: what sign-out leaves behind.
@MainActor
@Suite(.scratchDefaults)
struct SignOutHygieneTests {
    private static let account = Account(origin: URL(string: "https://127.0.0.1:9")!, clientID: "cid", scopes: [])

    private static func environment(
        store: any AccountStore, poster: RecordingRemovals
    ) -> AppEnvironment {
        AppEnvironment(
            auth: AuthCoordinator(store: store),
            defaults: ScratchDefaults.make(),
            notificationPoster: poster,
            isApplicationActive: { false }
        )
    }

    /// A successful sign-out purges the Herald-only preferences and withdraws
    /// the account's delivered banners. Fails if the banners are left in
    /// Notification Centre (a click would route to a gone account).
    @Test("A sign-out purges preferences and withdraws the account's banners")
    func successfulSignOutCleansUp() async throws {
        let poster = RecordingRemovals()
        let environment = Self.environment(store: InMemoryAccountStore(accounts: [Self.account]), poster: poster)
        await environment.install(account: Self.account, api: FakeMailAPIClient(), store: try MailStore.inMemory())
        DomainPreferences.setHidden(true, accountID: Self.account.id, domainID: "dom", in: environment.defaults)

        await environment.signOut(accountID: Self.account.id)

        #expect(await poster.removed == [Self.account.id])
        #expect(DomainPreferences.hiddenDomainIDs(accountID: Self.account.id, in: environment.defaults).isEmpty)
    }

    /// A sign-out whose Keychain half FAILED keeps the preferences: the account
    /// comes back at the next launch and must come back with them. Fails on
    /// the old unconditional purge. Banners still go — this session is done
    /// with the account either way.
    @Test("A failed sign-out keeps the account's preferences")
    func failedSignOutKeepsPreferences() async throws {
        let poster = RecordingRemovals()
        let environment = Self.environment(store: UnremovableAccountStore(account: Self.account), poster: poster)
        await environment.install(account: Self.account, api: FakeMailAPIClient(), store: try MailStore.inMemory())
        DomainPreferences.setHidden(true, accountID: Self.account.id, domainID: "dom", in: environment.defaults)

        await environment.signOut(accountID: Self.account.id)

        #expect(environment.signInError != nil, "the failure was reported")
        #expect(DomainPreferences.hiddenDomainIDs(accountID: Self.account.id, in: environment.defaults) == ["dom"])
        #expect(await poster.removed == [Self.account.id])
    }

    /// A banner clicked before its account's graph came up is held for it;
    /// signing that account out must drop it, or a later sign-in replays a
    /// click about mail the user already walked away from.
    @Test("Signing out drops a click held for the account")
    func signOutDropsPendingRoute() async throws {
        let poster = RecordingRemovals()
        let environment = Self.environment(store: InMemoryAccountStore(accounts: [Self.account]), poster: poster)
        await environment.open(NewMailRoute(accountID: Self.account.id, threadID: "t1", messageID: "m1"))
        #expect(environment.pendingRouteForTesting?.accountID == Self.account.id, "control: held")

        await environment.signOut(accountID: Self.account.id)

        #expect(environment.pendingRouteForTesting == nil)
    }

    /// The matching rule on its own: the account's prefix AND payload. Fails
    /// on a bare prefix test, which also matched an account whose id extends
    /// this one's with a dot.
    @Test("Delivered-banner matching needs the prefix and the payload")
    func deliveredMatching() {
        let id = "https://mail.x"
        let mine = NewMailNotification.identifierPrefix(accountID: id) + "m1"
        #expect(NewMailNotification.isForAccount(id, identifier: mine, userInfo: [NewMailNotification.accountIDKey: id]))
        let longer = "https://mail.x.y"
        let theirs = NewMailNotification.identifierPrefix(accountID: longer) + "m1"
        #expect(theirs.hasPrefix(NewMailNotification.identifierPrefix(accountID: id)), "fixture: the prefix alone is ambiguous")
        #expect(!NewMailNotification.isForAccount(id, identifier: theirs, userInfo: [NewMailNotification.accountIDKey: longer]))
        #expect(!NewMailNotification.isForAccount(id, identifier: "other.id", userInfo: [NewMailNotification.accountIDKey: id]))
    }
}

/// Records `removeDelivered(forAccount:)` and posts nothing.
private actor RecordingRemovals: NewMailNotificationPosting {
    private(set) var removed: [String] = []
    func requestAuthorization() async -> Bool { false }
    func post(_ notification: NewMailNotification) async {}
    func removeDelivered(forAccount accountID: String) async { removed.append(accountID) }
}

/// Lists its account but refuses to remove it — `AuthCoordinator.signOut`'s
/// Keychain half fails.
private nonisolated final class UnremovableAccountStore: AccountStore {
    private let backing: InMemoryAccountStore
    init(account: Account) { backing = InMemoryAccountStore(accounts: [account]) }
    func accounts() throws -> [Account] { try backing.accounts() }
    func add(_ account: Account) throws { try backing.add(account) }
    func remove(_ accountID: Account.ID) throws { throw AccountStoreError.indexUnreadable }
    func tokens(for accountID: Account.ID) throws -> OAuthTokens? { try backing.tokens(for: accountID) }
    func setTokens(_ tokens: OAuthTokens?, for accountID: Account.ID) throws { try backing.setTokens(tokens, for: accountID) }
    func setTokens(_ tokens: OAuthTokens?, for accountID: Account.ID, ifRefreshTokenIs expected: String) throws -> Bool {
        try backing.setTokens(tokens, for: accountID, ifRefreshTokenIs: expected)
    }
    func clientID(for origin: URL) throws -> String? { try backing.clientID(for: origin) }
    func setClientID(_ clientID: String, for origin: URL) throws { try backing.setClientID(clientID, for: origin) }
    func forgetClientID(_ clientID: String, for origin: URL) throws -> Bool { try backing.forgetClientID(clientID, for: origin) }
}
