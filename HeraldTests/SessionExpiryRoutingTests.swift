import Foundation
import HeraldKit
import Testing
@testable import Herald

/// Mints a fresh grant per refresh (`access-N` / `refresh-N`), the way a
/// pre-1.4.2 HQBase keeps doing for a web session that no longer exists.
private actor MintingRefresher: TokenRefreshing {
    private(set) var callCount = 0

    func refresh(refreshToken: String) async throws -> OAuthTokens {
        callCount += 1
        return OAuthTokens(
            accessToken: "access-\(callCount)",
            refreshToken: "refresh-\(callCount)",
            expiresAt: Date().addingTimeInterval(3600),
            scope: "mail:read mail:write mail:send offline_access"
        )
    }
}

/// Answers EVERY request `401 invalid_token` and counts them — a server whose
/// bound web session is gone. Scoped per session by a header, so suites
/// running in parallel never share a count.
private nonisolated final class DeadSessionProtocol: URLProtocol, @unchecked Sendable {
    private static let header = "X-Dead-Session-Test"
    private static let counts = DeadSessionRequestCounts()

    /// A session whose requests all land here, and the key its count is under.
    static func session() -> (URLSession, String) {
        let key = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeadSessionProtocol.self]
        configuration.httpAdditionalHeaders = [header: key]
        return (URLSession(configuration: configuration), key)
    }

    static func requestCount(_ key: String) -> Int { counts.value(key) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if let key = request.value(forHTTPHeaderField: Self.header) { Self.counts.increment(key) }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 401,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "WWW-Authenticate": #"Bearer error="invalid_token""#,
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":{"code":"INVALID_OAUTH_TOKEN","message":"dead"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A lock-guarded counter map; `URLProtocol` instances are created off the
/// main actor, so this cannot be actor state.
private nonisolated final class DeadSessionRequestCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func increment(_ key: String) { lock.withLock { counts[key, default: 0] += 1 } }
    func value(_ key: String) -> Int { lock.withLock { counts[key, default: 0] } }
}

/// P2 of the 2026-09-26 session-recovery plan: EVERY dead-session signal reaches
/// the account's ONE transition into `.needsReauth`.
///
/// Before it, only the sync loop and the wake socket escalated. A send, a draft
/// autosave, a message open, an auto mark-read or a signature read that hit a
/// dead session failed with a generic error and nothing else happened until
/// the next poll — the incident's "Send just says it failed". The provider's
/// hook (P1) is the one signal; these pin that the app routes it to the right
/// account, once, and never to an account that has gone.
@MainActor
@Suite struct SessionExpiryRoutingTests {
    private static let accountA = Account(origin: URL(string: "https://127.0.0.1:9")!, clientID: "cid", scopes: [])
    private static let accountB = Account(origin: URL(string: "https://127.0.0.1:19")!, clientID: "cid", scopes: [])

    private static func tokens(_ n: Int) -> OAuthTokens {
        OAuthTokens(
            accessToken: "access-\(n)",
            refreshToken: "refresh-\(n)",
            expiresAt: Date().addingTimeInterval(3600),
            scope: "mail:read mail:write mail:send offline_access"
        )
    }

    private static func scratchDefaults() -> UserDefaults {
        let suite = "SessionExpiryRoutingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Herald in the BACKGROUND by default: the automatic attempt is then
    /// deferred (no consent window, no network), so these tests observe the
    /// transition itself. The one test about the attempt passes `true`.
    private static func environment(
        accounts: [Account],
        tracker: RecordingUsageTracker = RecordingUsageTracker(),
        active: Bool = false
    ) -> AppEnvironment {
        AppEnvironment(
            auth: AuthCoordinator(store: InMemoryAccountStore(accounts: accounts)),
            defaults: scratchDefaults(),
            usage: tracker,
            isApplicationActive: { active }
        )
    }

    /// A provider over its OWN token store, seeded with `seed`. Separate from
    /// the environment's `AuthCoordinator` store on purpose: signing out clears
    /// that one, and a provider that then found no grant would announce nothing
    /// — which would make the sign-out test pass without the environment's
    /// guard.
    private static func provider(
        for account: Account,
        seed: OAuthTokens = tokens(0),
        store: InMemoryAccountStore = InMemoryAccountStore()
    ) throws -> (AccountTokenProvider, InMemoryAccountStore) {
        try store.setTokens(seed, for: account.id)
        let provider = AccountTokenProvider(
            accountID: account.id, store: store, refresher: MintingRefresher(), refreshLeeway: 60
        )
        return (provider, store)
    }

    /// Installs `account` with a HEALTHY fake API (so the sync loop never
    /// reports anything) and `provider` as its token provider, and counts the
    /// view-model's announcements while still forwarding them to the policy.
    private static func install(
        _ account: Account,
        provider: AccountTokenProvider,
        in environment: AppEnvironment,
        store: MailStore,
        select: Bool = true
    ) async -> AnnouncementLog {
        await environment.install(
            account: account, api: FakeMailAPIClient(), store: store, select: select, tokenProvider: provider
        )
        // What `activate` does for a real account (pinned through `activate`
        // itself by `activateWiresTheProvidersDeathsToTheBanner`).
        await provider.setSessionRejectedHandler(environment.sessionDeathHandler())
        let log = AnnouncementLog()
        let graph = environment.graphs[account.id]!
        let forward = graph.mail.reauthenticationRequired
        graph.mail.reauthenticationRequired = { id in
            log.ids.append(id)
            forward?(id)
        }
        return log
    }

    @MainActor final class AnnouncementLog {
        var ids: [Account.ID] = []
    }

    actor DeathCapture {
        private(set) var death: SessionDeath?
        func set(_ death: SessionDeath) { self.death = death }
    }

    // MARK: - Non-sync surfaces raise the banner

    /// The incident's surface: message detail and send, through the REAL
    /// middleware and provider (401 → refresh → 401), on a client that is not
    /// the sync loop's. Fails on the pre-P2 app: the provider latched and
    /// announced into a handler nobody had set, the view-model stayed `.idle`,
    /// and the user got a generic failure with no way back in.
    @Test func aMessageOpenAndASendThatHitADeadSessionRaiseTheBannerOnce() async throws {
        let environment = Self.environment(accounts: [Self.accountA])
        let (provider, _) = try Self.provider(for: Self.accountA)
        let log = await Self.install(Self.accountA, provider: provider, in: environment, store: try MailStore.inMemory())
        let mail = try #require(environment.graphs[Self.accountA.id]?.mail)
        #expect(mail.status != .needsReauth)

        let (session, key) = DeadSessionProtocol.session()
        let client = HQBaseAPIClient(origin: Self.accountA.origin, tokens: provider, session: session)

        await #expect(throws: MailAPIError.unauthorized) { _ = try await client.message(id: "msg_01") }
        #expect(mail.status == .needsReauth, "a message open that found the session dead raised no banner")
        #expect(log.ids == [Self.accountA.id])

        let outbox = OutboxService(api: client)
        let draft = ComposeDraft(mode: .new(mailboxID: nil), fromAddress: "a@example.com", to: ["b@example.com"], subject: "Hi", body: "Hello")
        do {
            _ = try await outbox.send(draft)
            Issue.record("a send on a dead session succeeded")
        } catch {
            // What P4's compose error bar keys on.
            #expect(error == .api(.unauthorized))
            #expect(MailViewModel.requiresReauthentication(error))
        }
        // The latched grant fails fast: the send never reached the server.
        #expect(DeadSessionProtocol.requestCount(key) == 2)
        #expect(log.ids == [Self.accountA.id], "one death was announced more than once")
    }

    /// Sync, the socket and the provider hook discover the same death within
    /// moments. Fails if any of them announces on its own rather than through
    /// the one transition — two automatic attempts (two consent windows) for
    /// one expiry.
    @Test func theHookTheSocketAndSyncTogetherAnnounceOneExpiry() async throws {
        let environment = Self.environment(accounts: [Self.accountA])
        let (provider, _) = try Self.provider(for: Self.accountA)
        let log = await Self.install(Self.accountA, provider: provider, in: environment, store: try MailStore.inMemory())
        let mail = try #require(environment.graphs[Self.accountA.id]?.mail)

        await provider.sessionRejected(token: "access-0")
        mail.reportSessionExpired()  // the wake socket's path
        await provider.sessionRejected(token: "access-0")
        environment.reportSessionExpired(accountID: Self.accountA.id)

        #expect(mail.status == .needsReauth)
        #expect(log.ids == [Self.accountA.id])
    }

    // MARK: - Per account

    /// Multi-account shares one Keychain. Fails if the hook is routed to the
    /// selected account, or to every account, instead of the one whose grant
    /// died.
    @Test func anotherAccountsDeathLeavesThisAccountAlone() async throws {
        let environment = Self.environment(accounts: [Self.accountA, Self.accountB])
        let store = try MailStore.inMemory()
        let keychain = InMemoryAccountStore()
        let (providerA, _) = try Self.provider(for: Self.accountA, store: keychain)
        let (providerB, _) = try Self.provider(for: Self.accountB, seed: Self.tokens(7), store: keychain)
        let logA = await Self.install(Self.accountA, provider: providerA, in: environment, store: store)
        let logB = await Self.install(Self.accountB, provider: providerB, in: environment, store: store, select: false)
        #expect(environment.selectedAccountID == Self.accountA.id)

        await providerB.sessionRejected(token: "access-7")

        #expect(environment.graphs[Self.accountB.id]?.mail.status == .needsReauth)
        #expect(logB.ids == [Self.accountB.id])
        #expect(environment.graphs[Self.accountA.id]?.mail.status != .needsReauth, "a background account's death flipped the selected one")
        #expect(logA.ids.isEmpty)
        #expect(try await providerA.accessToken() == "access-0")
    }

    // MARK: - Re-auth and sign-out

    /// A re-auth installs a NEW graph (and provider) for the same account id.
    /// Fails if the new graph inherits the banner, or if the new grant's own
    /// death is not announced — the second expiry would then wait for a poll.
    /// Also pins the superseded provider (an open composer's) reporting on the
    /// CURRENT grant: that report is about the live session and must reach the
    /// current graph, not the stopped one.
    @Test func afterReauthTheNewGraphIsHealthyAndALaterDeathAnnouncesAgain() async throws {
        let environment = Self.environment(accounts: [Self.accountA])
        let mailStore = try MailStore.inMemory()
        let keychain = InMemoryAccountStore()
        let (oldProvider, _) = try Self.provider(for: Self.accountA, store: keychain)
        let oldLog = await Self.install(Self.accountA, provider: oldProvider, in: environment, store: mailStore)
        await oldProvider.sessionRejected(token: "access-0")
        #expect(environment.graphs[Self.accountA.id]?.mail.status == .needsReauth)
        #expect(oldLog.ids.count == 1)

        // The sign-in writes a new grant, then installs a new graph.
        let (newProvider, _) = try Self.provider(for: Self.accountA, seed: Self.tokens(9), store: keychain)
        let newLog = await Self.install(Self.accountA, provider: newProvider, in: environment, store: mailStore)
        let newMail = try #require(environment.graphs[Self.accountA.id]?.mail)
        #expect(newMail.status != .needsReauth, "the new graph came up behind the old banner")

        // The superseded provider — still held by a composer — hits the NEW
        // grant's death first.
        await oldProvider.sessionRejected(token: "access-9")
        #expect(newMail.status == .needsReauth)
        #expect(newLog.ids == [Self.accountA.id])
        #expect(oldLog.ids.count == 1, "the report went to the superseded graph")

        // The new graph's own provider reporting the same death adds nothing.
        await newProvider.sessionRejected(token: "access-9")
        #expect(newLog.ids == [Self.accountA.id])
    }

    /// Fails if a report landing after sign-out brings the account back — a
    /// graph, a banner, or an automatic sign-in that re-installs it. The
    /// provider still holds a grant (its store is not the one sign-out cleared),
    /// so it DOES announce; only the environment's guard keeps it out.
    @Test func aReportAfterSignOutIsANoOp() async throws {
        let tracker = RecordingUsageTracker()
        let environment = Self.environment(accounts: [Self.accountA], tracker: tracker, active: true)
        let (provider, _) = try Self.provider(for: Self.accountA)
        _ = await Self.install(Self.accountA, provider: provider, in: environment, store: try MailStore.inMemory())

        await environment.signOut(accountID: Self.accountA.id)
        #expect(environment.graphs[Self.accountA.id] == nil)

        await provider.sessionRejected(token: "access-0")
        // Proof the announcement really fired: the grant is latched.
        await #expect(throws: OAuthError.reauthenticationRequired) { _ = try await provider.accessToken() }

        await environment.drainPendingUsage()
        #expect(environment.graphs[Self.accountA.id] == nil, "a late report resurrected a signed-out account")
        #expect(environment.accountIDs.isEmpty)
        #expect(environment.isReauthenticating(accountID: Self.accountA.id) == false)
        #expect(await tracker.names.contains("account_reauthenticated") == false)
    }

    // MARK: - Stale reports (W11)

    /// A provider read the store, found the grant dead and announced it — and
    /// the announcement reached the main actor only AFTER a re-auth had stored
    /// a new grant and installed a new graph. Fails if the stale report is
    /// routed by account id onto the fresh graph (the banner, and an automatic
    /// consent window, over a session that works). The positive control: the
    /// same report for the grant still stored does raise it.
    @Test func aStaleDeathReportDoesNotRaiseTheBannerOnAFreshGraph() async throws {
        let environment = Self.environment(accounts: [Self.accountA])
        let mailStore = try MailStore.inMemory()
        let keychain = InMemoryAccountStore()
        let (oldProvider, _) = try Self.provider(for: Self.accountA, store: keychain)
        _ = await Self.install(Self.accountA, provider: oldProvider, in: environment, store: mailStore)
        // The old provider's announcement, captured in flight (not yet delivered).
        let captured = DeathCapture()
        await oldProvider.setSessionRejectedHandler { await captured.set($0) }
        await oldProvider.sessionRejected(token: "access-0")
        let staleDeath = try #require(await captured.death)

        // The re-auth lands first: new grant, new graph.
        let (newProvider, _) = try Self.provider(for: Self.accountA, seed: Self.tokens(9), store: keychain)
        let newLog = await Self.install(Self.accountA, provider: newProvider, in: environment, store: mailStore)
        let newMail = try #require(environment.graphs[Self.accountA.id]?.mail)

        await environment.reportSessionDeath(staleDeath)
        #expect(newMail.status != .needsReauth, "a stale report raised the banner over a fresh sign-in")
        #expect(newLog.ids.isEmpty)

        // Control: a death of the grant that IS stored is delivered.
        await newProvider.sessionRejected(token: "access-9")
        #expect(newMail.status == .needsReauth)
        #expect(newLog.ids == [Self.accountA.id])
    }

    /// The other half of the check: the store still held the dead grant when
    /// the provider was asked, but the graph the report was pinned to was
    /// replaced while it asked. Fails if the report is delivered to whatever
    /// graph is installed afterwards instead of being dropped.
    @Test func aDeathReportThatRacesAReinstallIsDropped() async throws {
        let environment = Self.environment(accounts: [Self.accountA])
        let mailStore = try MailStore.inMemory()
        let keychain = ReadGatedAccountStore()
        let (provider, _) = try Self.provider(for: Self.accountA, store: keychain.backing)
        let gatedProvider = AccountTokenProvider(
            accountID: Self.accountA.id, store: keychain, refresher: MintingRefresher(), refreshLeeway: 60
        )
        _ = await Self.install(Self.accountA, provider: provider, in: environment, store: mailStore)
        let oldMail = try #require(environment.graphs[Self.accountA.id]?.mail)
        let captured = DeathCapture()
        await gatedProvider.setSessionRejectedHandler { await captured.set($0) }
        await gatedProvider.sessionRejected(token: "access-0")
        let death = try #require(await captured.death)

        keychain.armReadGate()
        let report = Task { await environment.reportSessionDeath(death) }
        try await wait("the report to be checking the store") { keychain.isBlocked }
        let newLog = await Self.install(Self.accountA, provider: provider, in: environment, store: mailStore)
        keychain.openReadGate()
        await report.value

        let newMail = try #require(environment.graphs[Self.accountA.id]?.mail)
        #expect(newMail !== oldMail)
        #expect(newMail.status != .needsReauth, "a report that raced a re-install reached the new graph")
        #expect(newLog.ids.isEmpty)
        #expect(oldMail.status != .needsReauth, "a report that raced a re-install was delivered anyway")
    }

    // MARK: - activate wires the provider (D6, D9)

    /// Through `activate` itself — the real `AuthCoordinator.tokenProvider`, the
    /// real `HQBaseAPIClient` — not a test-side `install`. Fails if `activate`
    /// stops wiring the provider it builds: a send, an autosave or a message
    /// open on a dead session would then latch silently and raise no banner.
    /// (Sync cannot mask it here: the origin never resolves, so every pass
    /// fails as a transport error, never as a dead session.)
    @Test func activateWiresTheProvidersDeathsToTheBanner() async throws {
        let account = Account(
            origin: URL(string: "https://\(OAuTestServerConstants.host)")!, clientID: "cid_registered", scopes: []
        )
        let keychain = InMemoryAccountStore(accounts: [account])
        try keychain.setTokens(Self.tokens(0), for: account.id)
        let environment = AppEnvironment(
            auth: AuthCoordinator(store: keychain, presenter: PendingPresenter(), session: OAuthTestServer.session()),
            defaults: Self.scratchDefaults(),
            isApplicationActive: { false }
        )
        environment.store = try MailStore.inMemory()

        #expect(await environment.activate(account))
        let graph = try #require(environment.graphs[account.id])
        let provider = try #require(graph.tokens, "activate did not keep its provider on the graph")
        #expect(graph.mail.status != .needsReauth)

        await provider.sessionRejected(token: "access-0")

        #expect(graph.mail.status == .needsReauth, "activate left the provider's dead-session hook unwired")
        await environment.stopGraph(accountID: account.id)
    }

    // MARK: - The automatic attempt

    /// End to end into the policy: a non-sync death, Herald frontmost, the
    /// account selected — the automatic attempt runs at once (and fails here,
    /// the origin being unreachable). Fails if the hook stops at the banner.
    @Test func aHookReportStartsTheAutomaticAttempt() async throws {
        let tracker = RecordingUsageTracker()
        let environment = Self.environment(accounts: [Self.accountA], tracker: tracker, active: true)
        let (provider, _) = try Self.provider(for: Self.accountA)
        await environment.install(
            account: Self.accountA, api: FakeMailAPIClient(), store: try MailStore.inMemory(), tokenProvider: provider
        )
        await provider.setSessionRejectedHandler(environment.sessionDeathHandler())
        await environment.setWindowActive(true)

        await provider.sessionRejected(token: "access-0")

        try await wait("the automatic attempt to run") {
            await environment.drainPendingUsage()
            return await tracker.names.contains("account_reauthenticated")
        }
        let reauths = await tracker.events.filter { $0.name == "account_reauthenticated" }
        #expect(reauths.count == 1)
        #expect(reauths.first?.props["automatic"] == .bool(true))
    }

    // MARK: - Classification (P4 uses it for the compose error bar)

    @Test(arguments: [
        (OutboxError.api(.unauthorized) as any Error, true),
        (SignatureManagementError.api(.unauthorized) as any Error, true),
        (MailAPIError.unauthorized as any Error, true),
        (OAuthError.reauthenticationRequired as any Error, true),
        (OAuthError.missingRefreshToken as any Error, true),
        (OutboxError.api(.notFound) as any Error, false),
        (OutboxError.draftConflict as any Error, false),
        (SignatureManagementError.notAuthorized as any Error, false),
    ])
    func requiresReauthenticationSeesThroughTheServiceWrappers(error: any Error, expected: Bool) {
        #expect(MailViewModel.requiresReauthentication(error) == expected)
    }
}

/// An in-memory store whose token READ can be made to block, so a
/// `SessionDeath.isCurrent()` check can be held while the main actor re-installs
/// the account.
private nonisolated final class ReadGatedAccountStore: AccountStore, @unchecked Sendable {
    let backing = InMemoryAccountStore()
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed = false
    private var blocked = false

    var isBlocked: Bool { lock.withLock { blocked } }
    /// The NEXT `tokens(for:)` blocks until ``openReadGate()``.
    func armReadGate() { lock.withLock { armed = true } }
    func openReadGate() { gate.signal() }

    func tokens(for accountID: Account.ID) throws -> OAuthTokens? {
        let shouldBlock = lock.withLock { () -> Bool in
            guard armed else { return false }
            armed = false
            blocked = true
            return true
        }
        if shouldBlock {
            gate.wait()
            lock.withLock { blocked = false }
        }
        return try backing.tokens(for: accountID)
    }

    func accounts() throws -> [Account] { try backing.accounts() }
    func add(_ account: Account) throws { try backing.add(account) }
    func remove(_ accountID: Account.ID) throws { try backing.remove(accountID) }
    func setTokens(_ tokens: OAuthTokens?, for accountID: Account.ID) throws {
        try backing.setTokens(tokens, for: accountID)
    }
    func clientID(for origin: URL) throws -> String? { try backing.clientID(for: origin) }
    func setClientID(_ clientID: String, for origin: URL) throws { try backing.setClientID(clientID, for: origin) }
    func forgetClientID(_ clientID: String, for origin: URL) throws -> Bool { try backing.forgetClientID(clientID, for: origin) }
}
