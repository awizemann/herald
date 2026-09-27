import Foundation
import Testing
@testable import HeraldKit

/// A token endpoint that binds every grant to the client it was issued to, the
/// way better-auth's oauth-provider does: a refresh sent as a client the server
/// does not know is `invalid_client`; as a known client that is not the grant's,
/// `invalid_grant`. Rotates on success, bound to the same client.
///
/// `ownClientID` is the id the refresher sends when the provider does not say
/// (``TokenRefreshing/refresh(refreshToken:)``) — the client a provider
/// CAPTURED at build, which is what the pre-P9a code always sent.
nonisolated final class ClientBoundRefresher: TokenRefreshing, @unchecked Sendable {
    typealias Interception = @Sendable (Int) throws -> Void

    private let lock = NSLock()
    private let ownClientID: String
    private var knownClients: Set<String>
    private var grants: [String: String]
    private var issued = 0
    private var calls: [(token: String, clientID: String)] = []
    private let intercept: Interception

    init(
        ownClientID: String,
        knownClients: Set<String>,
        grants: [String: String],
        intercept: @escaping Interception = { _ in }
    ) {
        self.ownClientID = ownClientID
        self.knownClients = knownClients
        self.grants = grants
        self.intercept = intercept
    }

    var sentClientIDs: [String] { lock.withLock { calls.map(\.clientID) } }
    var callCount: Int { lock.withLock { calls.count } }

    func refresh(refreshToken: String) async throws -> OAuthTokens {
        try await refresh(refreshToken: refreshToken, clientID: nil)
    }

    func refresh(refreshToken: String, clientID: String?) async throws -> OAuthTokens {
        let sent = clientID ?? ownClientID
        let index = lock.withLock { () -> Int in
            calls.append((refreshToken, sent))
            return calls.count
        }
        // Stands in for the other process (or graph) acting while this request
        // is on the wire — BEFORE the server judges it.
        try intercept(index)
        return try lock.withLock {
            guard knownClients.contains(sent) else {
                throw OAuthError.server(error: "invalid_client", description: "missing client")
            }
            guard grants[refreshToken] == sent else {
                throw OAuthError.server(error: "invalid_grant", description: "client mismatch")
            }
            grants[refreshToken] = nil
            issued += 1
            let fresh = "refresh-new-\(issued)"
            grants[fresh] = sent
            return OAuthTokens(
                accessToken: "access-new-\(issued)",
                refreshToken: fresh,
                expiresAt: Date().addingTimeInterval(3600),
                scope: "mail:read offline_access"
            )
        }
    }
}

/// Session recovery, round 2 (P9a): client-id resolution at refresh time (A),
/// scope refusals that must rediscover and re-register (C), sign-out forgetting
/// the last registration (F) and ordering its generation bump before the revoke
/// (H), a generation-refused refresh as a re-auth death (I), and the two nits.
@Suite nonisolated struct SessionRecoveryP9aTests {
    private static let origin = AuthFixtures.origin
    private static let accountID = AuthFixtures.origin.absoluteString

    private static func tokens(_ refresh: String, expiresIn: TimeInterval = -60) -> OAuthTokens {
        OAuthTokens(
            accessToken: "access-\(refresh)",
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            scope: "mail:read offline_access"
        )
    }

    /// How the server refuses a request sent as the OLD client: it still knows
    /// that client (the grant is simply not its: `invalid_grant`), or it has
    /// forgotten it (`invalid_client`).
    static let oldClientKnown = [true, false]

    // MARK: - A: client id resolved at refresh time

    /// The superseded graph's provider (an open composer's outbox) — or a second
    /// Herald process — was built when the account's client was `cid_old`. A
    /// re-auth since re-registered: the record and the grant are `cid_new`'s.
    /// Pre-fix it refreshed the NEW grant as `cid_old`: `invalid_grant` cleared
    /// the shared healthy grant (everyone signed out), `invalid_client` latched
    /// it and raised the banner over a healthy session.
    @Test("a superseded provider refreshes the current grant as the current client", arguments: oldClientKnown)
    func supersededProviderUsesCurrentClient(_ oldKnown: Bool) async throws {
        let store = RecordingAccountStore(clientIDs: [Self.origin.absoluteString: "cid_new"])
        try store.add(Account(origin: Self.origin, clientID: "cid_new", scopes: []))
        try store.setTokens(Self.tokens("refresh-2"), for: Self.accountID)
        let refresher = ClientBoundRefresher(
            ownClientID: "cid_old",
            knownClients: oldKnown ? ["cid_old", "cid_new"] : ["cid_new"],
            grants: ["refresh-2": "cid_new"]
        )
        let provider = AccountTokenProvider(
            accountID: Self.accountID, store: store, refresher: refresher, refreshLeeway: 60,
            origin: Self.origin, clientID: "cid_old"
        )
        let recorder = RejectionRecorder()
        await provider.setSessionRejectedHandler { await recorder.record($0.accountID) }

        #expect(try await provider.accessToken() == "access-new-1")
        #expect(refresher.sentClientIDs == ["cid_new"])
        #expect(await recorder.count == 0, "a healthy grant was announced dead")
        #expect(try store.tokens(for: Self.accountID)?.refreshToken == "refresh-new-1")
        #expect(try store.clientID(for: Self.origin) == "cid_new")
    }

    /// The re-registration lands while the refresh is on the wire: the grant in
    /// the store is already the new client's (a sign-in writes the record
    /// before the tokens), the record flips while we wait. The refusal is about
    /// the id we SENT, not the grant — so it is superseded: re-read and go again
    /// as the current id. Never cleared, latched, forgotten or announced.
    @Test("a refusal for a request sent as a since-replaced client id is retried as the current one", arguments: oldClientKnown)
    func refusalForSupersededClientRetries(_ oldKnown: Bool) async throws {
        let store = RecordingAccountStore(clientIDs: [Self.origin.absoluteString: "cid_new"])
        try store.add(Account(origin: Self.origin, clientID: "cid_old", scopes: []))
        try store.setTokens(Self.tokens("refresh-2"), for: Self.accountID)
        let refresher = ClientBoundRefresher(
            ownClientID: "cid_old",
            knownClients: oldKnown ? ["cid_old", "cid_new"] : ["cid_new"],
            grants: ["refresh-2": "cid_new"]
        ) { call in
            if call == 1 { try store.add(Account(origin: Self.origin, clientID: "cid_new", scopes: [])) }
        }
        let provider = AccountTokenProvider(
            accountID: Self.accountID, store: store, refresher: refresher, refreshLeeway: 60,
            origin: Self.origin, clientID: "cid_old"
        )
        let recorder = RejectionRecorder()
        await provider.setSessionRejectedHandler { await recorder.record($0.accountID) }

        #expect(try await provider.accessToken() == "access-new-1")
        #expect(refresher.sentClientIDs == ["cid_old", "cid_new"])
        #expect(await recorder.count == 0)
        #expect(try store.tokens(for: Self.accountID)?.refreshToken == "refresh-new-1")
        #expect(try store.clientID(for: Self.origin) == "cid_new")
    }

    /// Bounded: a record that changes on EVERY attempt gives up after one
    /// superseded retry — with no verdict (nothing cleared, latched or
    /// announced), so the next request simply tries again.
    @Test("superseded retries are bounded and leave no verdict")
    func supersededRetriesAreBounded() async throws {
        let store = RecordingAccountStore(clientIDs: [Self.origin.absoluteString: "cid_1"])
        try store.add(Account(origin: Self.origin, clientID: "cid_0", scopes: []))
        try store.setTokens(Self.tokens("refresh-2"), for: Self.accountID)
        let refresher = ClientBoundRefresher(ownClientID: "cid_0", knownClients: [], grants: [:]) { call in
            try store.add(Account(origin: Self.origin, clientID: "cid_\(call)", scopes: []))
        }
        let provider = AccountTokenProvider(
            accountID: Self.accountID, store: store, refresher: refresher, refreshLeeway: 60,
            origin: Self.origin, clientID: "cid_0"
        )
        let recorder = RejectionRecorder()
        await provider.setSessionRejectedHandler { await recorder.record($0.accountID) }

        await #expect(throws: OAuthError.server(error: "invalid_client", description: "missing client")) {
            _ = try await provider.accessToken()
        }
        #expect(refresher.callCount == 2)
        #expect(await recorder.count == 0)
        #expect(try store.tokens(for: Self.accountID)?.refreshToken == "refresh-2")
        #expect(try store.clientID(for: Self.origin) == "cid_1", "a superseded refusal forgot a registration")

        // Not latched: the next request spends the grant again.
        _ = try? await provider.accessToken()
        #expect(refresher.callCount > 2)
    }

    /// End to end through the coordinator: a provider built from a STALE
    /// `Account` value sends the record's client id on the wire.
    @Test("the coordinator's provider sends the account record's client id, not the one it was built with")
    @MainActor func coordinatorProviderReadsRecord() async throws {
        let server = AuthFixtures.fullServer()
        let store = RecordingAccountStore(clientIDs: [Self.origin.absoluteString: "cid_new"])
        let current = Account(origin: Self.origin, clientID: "cid_new", scopes: [])
        try store.add(current)
        try store.setTokens(Self.tokens("refresh-2"), for: current.id)
        let coordinator = AuthCoordinator(store: store, presenter: FakeAuthorizationPresenter.succeeding(), session: server.makeSession())

        var stale = current
        stale.clientID = "cid_old"
        let provider = try await coordinator.tokenProvider(for: stale)
        _ = try await provider.accessToken()

        let refresh = AuthFixtures.form(try #require(server.requests(path: AuthFixtures.tokenPath).last).bodyText)
        #expect(refresh["client_id"] == "cid_new")
    }

    // MARK: - C: scope refusals rediscover and re-register

    /// `invalid_scope` / `invalid_target`: the cached discovery and the
    /// scope-bound registration are what the server refused, so re-consenting
    /// with them can never succeed. Both are discarded (in memory and
    /// persisted) before the death is announced, and the next sign-in
    /// discovers and registers again.
    @Test("after a scope refusal the next sign-in rediscovers and re-registers", arguments: ["invalid_scope", "invalid_target"])
    @MainActor func scopeRefusalRediscovers(_ code: String) async throws {
        let server = AuthFixtures.fullServer()
        let store = KeychainAccountStore(secrets: InMemorySecretStore())
        let coordinator = AuthCoordinator(store: store, presenter: FakeAuthorizationPresenter.succeeding(), session: server.makeSession())
        let account = try await coordinator.addAccount(origin: Self.origin)
        #expect(server.requests(path: AuthFixtures.protectedResourcePath).count == 1)
        #expect(server.requests(path: AuthFixtures.registerPath).count == 1)
        #expect(try store.oauthConfiguration(for: Self.origin) != nil)

        server.route("POST", AuthFixtures.tokenPath, .json(400, #"{"error":"\#(code)"}"#), .json(200, AuthFixtures.tokenJSON()))
        try store.setTokens(Self.tokens("hqb_refresh_1"), for: account.id)
        let provider = try await coordinator.tokenProvider(for: account)
        let recorder = RejectionRecorder()
        await provider.setSessionRejectedHandler { await recorder.record($0.accountID) }

        await #expect(throws: OAuthError.reauthenticationRequired) { _ = try await provider.accessToken() }
        #expect(await recorder.count == 1)
        #expect(try store.clientID(for: Self.origin) == nil, "the scope-bound registration survived")
        #expect(try store.oauthConfiguration(for: Self.origin) == nil, "the persisted discovery survived")

        _ = try await coordinator.addAccount(origin: Self.origin)
        #expect(server.requests(path: AuthFixtures.protectedResourcePath).count == 2, "the re-auth reused the cached discovery")
        #expect(server.requests(path: AuthFixtures.registerPath).count == 2, "the re-auth reused the refused registration")
    }

    // MARK: - F: sign-out forgets the origin's last registration

    /// A server that forgot the client while nobody was signed in sent every
    /// Sign In to its error page — the stored `client.<origin>` outlived the
    /// sign-out. It goes with the origin's last account, and the next sign-in
    /// registers again.
    @Test("signing out the origin's last account forgets its registration and discovery")
    @MainActor func signOutForgetsLastRegistration() async throws {
        let server = AuthFixtures.fullServer()
        let store = KeychainAccountStore(secrets: InMemorySecretStore())
        let coordinator = AuthCoordinator(store: store, presenter: FakeAuthorizationPresenter.succeeding(), session: server.makeSession())
        let other = URL(string: "https://other.test.invalid")!
        try store.setClientID("cid_other", for: other)
        let account = try await coordinator.addAccount(origin: Self.origin)

        try await coordinator.signOut(account)

        #expect(try store.clientID(for: Self.origin) == nil)
        #expect(try store.oauthConfiguration(for: Self.origin) == nil)
        #expect(try store.clientID(for: other) == "cid_other", "another origin's registration was touched")
        _ = try await coordinator.addAccount(origin: Self.origin)
        #expect(server.requests(path: AuthFixtures.registerPath).count == 2)
    }

    /// Kept while another account on the origin remains (future multi-account):
    /// its grant was minted for that client.
    @Test("signing out keeps the registration while another account uses the origin")
    @MainActor func signOutKeepsSharedRegistration() async throws {
        let server = AuthFixtures.fullServer()
        let store = KeychainAccountStore(secrets: InMemorySecretStore())
        let coordinator = AuthCoordinator(store: store, presenter: FakeAuthorizationPresenter.succeeding(), session: server.makeSession())
        let account = try await coordinator.addAccount(origin: Self.origin)
        try store.add(Account(id: "second", origin: Self.origin, clientID: "cid_registered", scopes: []))

        try await coordinator.signOut(account)

        #expect(try store.clientID(for: Self.origin) == "cid_registered")
        #expect(try store.oauthConfiguration(for: Self.origin) != nil)
        #expect(try store.accounts().map(\.id) == ["second"])
    }

    // MARK: - H: generation bump before the revoke

    /// The sign-out generation is bumped (and discovery evicted) BEFORE the
    /// revoke goes out: a provider that tries to refresh while the revoke is on
    /// the wire is refused locally — pre-fix it resolved the still-cached
    /// endpoints and rotated the grant, so the revoke killed R1 while R2 stayed
    /// live on the server and was deleted locally.
    @Test("a provider cannot refresh while the sign-out's revoke is on the wire", .timeLimit(.minutes(1)))
    @MainActor func noRefreshDuringRevoke() async throws {
        let server = AuthFixtures.revokingServer()
        let store = RecordingAccountStore()
        let coordinator = AuthCoordinator(store: store, presenter: FakeAuthorizationPresenter.succeeding(), session: server.makeSession())
        let account = try await coordinator.addAccount(origin: Self.origin)
        try store.setTokens(Self.tokens("hqb_refresh_1"), for: account.id)
        let provider = try await coordinator.tokenProvider(for: account)
        let gate = server.gate("POST", AuthFixtures.revokePath)

        let signOut = Task { try await coordinator.signOut(account) }
        await gate.arrived()

        await #expect(throws: OAuthError.reauthenticationRequired) { _ = try await provider.accessToken() }
        #expect(server.requests(path: AuthFixtures.tokenPath).count == 1, "the grant was rotated during the revoke")

        gate.open()
        try await signOut.value
        let revoked = server.requests(path: AuthFixtures.revokePath).compactMap { AuthFixtures.form($0.bodyText)["token"] }
        #expect(revoked == ["hqb_refresh_1"])
        #expect(server.requests(path: AuthFixtures.protectedResourcePath).count == 1, "the sign-out rediscovered the origin")
        #expect(try store.tokens(for: account.id) == nil)
    }

    /// A refresh already past endpoint resolution can still land during the
    /// revoke. The store is re-read afterwards and the new refresh token is
    /// revoked too, so no live grant is orphaned on the server.
    @Test("a grant rotated during the revoke is revoked as well", .timeLimit(.minutes(1)))
    @MainActor func rotationDuringRevokeIsRevoked() async throws {
        let server = AuthFixtures.revokingServer()
        let store = RecordingAccountStore()
        let coordinator = AuthCoordinator(store: store, presenter: FakeAuthorizationPresenter.succeeding(), session: server.makeSession())
        let account = try await coordinator.addAccount(origin: Self.origin)
        let gate = server.gate("POST", AuthFixtures.revokePath)

        let signOut = Task { try await coordinator.signOut(account) }
        await gate.arrived()
        try store.setTokens(Self.tokens("rotated-2", expiresIn: 3600), for: account.id)
        gate.open()
        try await signOut.value

        let revoked = server.requests(path: AuthFixtures.revokePath).compactMap { AuthFixtures.form($0.bodyText)["token"] }
        #expect(revoked.sorted() == ["hqb_refresh_1", "rotated-2"])
        #expect(try store.tokens(for: account.id) == nil)
    }

    // MARK: - I: a generation-refused refresh is a re-auth death

    /// A provider stranded by its origin's sign-out (the account came back —
    /// an undo, another process) can never refresh again. That used to surface
    /// as transport ("Sync problem" forever, no Sign In); it is a re-auth death
    /// now: announced once, `.reauthenticationRequired`, no network, and the
    /// grant is NOT cleared (a newer provider may be using it).
    @Test("a refresh refused by the sign-out generation is announced as a re-auth death")
    @MainActor func strandedProviderAnnouncesDeath() async throws {
        let server = AuthFixtures.fullServer()
        let store = RecordingAccountStore(clientIDs: [Self.origin.absoluteString: "cid"])
        let account = Account(origin: Self.origin, clientID: "cid", scopes: [])
        try store.add(account)
        try store.setTokens(Self.tokens("refresh-1"), for: account.id)
        let coordinator = AuthCoordinator(store: store, presenter: FakeAuthorizationPresenter.succeeding(), session: server.makeSession())
        let provider = try await coordinator.tokenProvider(for: account)
        let recorder = RejectionRecorder()
        await provider.setSessionRejectedHandler { await recorder.record($0.accountID) }

        try await coordinator.signOut(account)
        try store.add(account)
        try store.setTokens(Self.tokens("refresh-1"), for: account.id)

        await #expect(throws: OAuthError.reauthenticationRequired) { _ = try await provider.accessToken() }
        await #expect(throws: OAuthError.reauthenticationRequired) { _ = try await provider.accessToken() }
        #expect(await recorder.count == 1)
        #expect(MailAPIError.mapping(OAuthError.reauthenticationRequired) == .unauthorized)
        #expect(server.requests(path: AuthFixtures.tokenPath).isEmpty)
        #expect(try store.tokens(for: account.id)?.refreshToken == "refresh-1")
    }

    // MARK: - Nits

    /// `unauthorized_client` for the client THIS sign-in just registered is the
    /// server's policy answer, not a lost registration: keep it, and surface
    /// the server's words instead of "no longer recognizes Herald".
    @Test("unauthorized_client for a just-registered client keeps it and is not reworded", arguments: [true, false])
    @MainActor func freshClientPolicyRefusal(_ onCallback: Bool) async throws {
        let server = AuthFixtures.fullServer()
        let store = RecordingAccountStore()
        let presenter: FakeAuthorizationPresenter
        if onCallback {
            presenter = FakeAuthorizationPresenter { url in
                let state = AuthFixtures.query(url)["state"] ?? ""
                return URL(string: "com.wizemann.herald:/oauth/callback?error=unauthorized_client&state=\(state)")!
            }
        } else {
            presenter = .succeeding()
            server.route("POST", AuthFixtures.tokenPath, .json(400, #"{"error":"unauthorized_client"}"#))
        }
        let coordinator = AuthCoordinator(store: store, presenter: presenter, session: server.makeSession())

        let expectedDescription = "The server refused to let Herald sign in (unauthorized_client). Ask your HQBase administrator to check its OAuth client settings."
        await #expect(throws: OAuthError.server(error: "unauthorized_client", description: expectedDescription)) {
            _ = try await coordinator.addAccount(origin: Self.origin)
        }
        #expect(server.requests(path: AuthFixtures.registerPath).count == 1)
        #expect(try store.clientID(for: Self.origin) == "cid_registered")

        // The user-visible description must be readable prose, not the bare
        // OAuth error code (audit fix for 46f2e27's reviewer).
        let error = OAuthError.server(error: "unauthorized_client", description: expectedDescription)
        #expect(error.errorDescription == expectedDescription)
        #expect(error.errorDescription != "unauthorized_client")
    }

    /// `setClientID` takes the same lock as `forgetClientID`'s compare-and-
    /// delete, so a registration written by this process while one runs is
    /// never lost. The spy pauses the compare (after it has read the old id)
    /// and lets a concurrent `setClientID` try to land; unlocked, it lands in
    /// the gap and the delete takes it with it.
    @Test("a registration written during forgetClientID survives it")
    func setClientIDSerializesWithForget() throws {
        let spy = PausingSecretStore()
        let store = KeychainAccountStore(secrets: spy)
        try store.setClientID("cid_old", for: Self.origin)
        let done = DispatchGroup()
        spy.onClientRead = {
            done.enter()
            let landed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                try? store.setClientID("cid_new", for: Self.origin)
                landed.signal()
                done.leave()
            }
            // Long enough for an unlocked write to land; a locked one waits.
            _ = landed.wait(timeout: .now() + 0.3)
        }

        #expect(try store.forgetClientID("cid_old", for: Self.origin))
        done.wait()
        #expect(try store.clientID(for: Self.origin) == "cid_new")
    }
}

/// Runs ``onClientRead`` (once) after reading a `client.` key and before
/// returning it — i.e. inside ``KeychainAccountStore/forgetClientID(_:for:)``'s
/// compare-and-delete.
nonisolated final class PausingSecretStore: SecretStore, @unchecked Sendable {
    private let base = InMemorySecretStore()
    private let lock = NSLock()
    private var hook: (@Sendable () -> Void)?

    var onClientRead: (@Sendable () -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue } }
    }

    func data(for key: String) throws -> Data? {
        let value = try base.data(for: key)
        if key.hasPrefix("client.") {
            let run = lock.withLock { () -> (@Sendable () -> Void)? in
                defer { hook = nil }
                return hook
            }
            run?()
        }
        return value
    }

    func set(_ data: Data, for key: String) throws { try base.set(data, for: key) }
    func removeValue(for key: String) throws { try base.removeValue(for: key) }
}
