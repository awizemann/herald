import Foundation
import Testing
@testable import HeraldKit

/// Audit W4: activation used to run live OAuth discovery
/// (`tokenProvider(for:)` → `configuration(for:)`), so a launch with the server
/// unreachable ended on "Herald could not start" and a secondary account never
/// got a graph. Discovery is now persisted at sign-in and resolved lazily.
@MainActor
@Suite struct OfflineActivationTests {
    private static let account = Account(origin: AuthFixtures.origin, clientID: "cid_registered", scopes: [])
    private static let expired = OAuthTokens(
        accessToken: "old_access",
        refreshToken: "old_refresh",
        expiresAt: Date(timeIntervalSince1970: 0)
    )

    /// A server whose discovery documents are gone (every `.well-known` path
    /// answers 501) but whose token endpoint works — "discovery cannot run".
    private static func noDiscoveryServer() -> FakeServer {
        let server = FakeServer()
        server.route("POST", AuthFixtures.tokenPath, .json(200, AuthFixtures.tokenJSON(access: "new_access")))
        return server
    }

    private static func seededStore(persisted: OAuthConfiguration?) throws -> (KeychainAccountStore, InMemorySecretStore) {
        let secrets = InMemorySecretStore()
        let store = KeychainAccountStore(secrets: secrets)
        try store.add(account)
        try store.setTokens(expired, for: account.id)
        if let persisted { try store.setOAuthConfiguration(persisted, for: account.origin) }
        return (store, secrets)
    }

    private static func eventually(_ condition: () throws -> Bool) async throws -> Bool {
        for _ in 0..<200 {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try condition()
    }

    /// The W4 fix itself. Fails if building the provider still needs discovery
    /// (it throws, which is the "could not start" launch), or if the refresh
    /// does not fall back to the endpoints persisted at sign-in.
    @Test("with discovery failing, a persisted configuration still activates and refreshes")
    func persistedConfigurationActivatesOffline() async throws {
        let server = Self.noDiscoveryServer()
        let (store, _) = try Self.seededStore(persisted: AuthFixtures.configuration)
        let coordinator = AuthCoordinator(store: store, presenter: FakeAuthorizationPresenter.succeeding(), session: server.makeSession())

        let provider = try await coordinator.tokenProvider(for: Self.account)
        #expect(try await provider.accessToken() == "new_access")

        let refresh = AuthFixtures.form(try #require(server.requests(path: AuthFixtures.tokenPath).first).bodyText)
        #expect(refresh["client_id"] == "cid_registered")
        #expect(refresh["resource"] == AuthFixtures.resource)
    }

    /// With NOTHING persisted (an account signed in before persistence existed)
    /// the provider still builds — the graph comes up — and the first refresh
    /// runs discovery, then persists it for the next launch. Fails if first
    /// activation stopped discovering, or never stored what it found.
    @Test("first activation with nothing persisted discovers on refresh and persists")
    func firstActivationDiscovers() async throws {
        let server = AuthFixtures.fullServer()
        let (store, _) = try Self.seededStore(persisted: nil)
        let coordinator = AuthCoordinator(store: store, presenter: FakeAuthorizationPresenter.succeeding(), session: server.makeSession())

        let provider = try await coordinator.tokenProvider(for: Self.account)
        _ = try await provider.accessToken()

        #expect(server.requests(path: AuthFixtures.suffixedMetadataPath).count == 1, "discovery ran more than once")
        #expect(server.requests(path: AuthFixtures.tokenPath).count == 1)
        #expect(try await Self.eventually { try store.oauthConfiguration(for: AuthFixtures.origin) != nil })
    }

    /// Nothing persisted AND no discovery: the provider still builds (so cached
    /// mail is readable), and a refresh fails as a TRANSPORT-shaped error — the
    /// normal "offline, retry later" — never as a dead session.
    @Test("with nothing persisted and discovery failing, refresh fails without killing the session")
    func nothingPersistedAndOffline() async throws {
        let server = FakeServer() // Nothing answers.
        let (store, _) = try Self.seededStore(persisted: nil)
        let coordinator = AuthCoordinator(store: store, presenter: FakeAuthorizationPresenter.succeeding(), session: server.makeSession())

        let provider = try await coordinator.tokenProvider(for: Self.account)
        do {
            _ = try await provider.accessToken()
            Issue.record("refresh succeeded with no endpoints")
        } catch {
            #expect(MailAPIError.mapping(error) != .unauthorized, "an unreachable server read as an expired session")
        }
        #expect(try store.tokens(for: Self.account.id) == Self.expired, "the grant was dropped for a network failure")
    }

    /// Fails if a persisted document is trusted without checking it belongs to
    /// this origin — the token request (carrying the refresh token) would go
    /// wherever it points.
    @Test(
        "a persisted configuration for another origin or off-origin endpoints is never used",
        arguments: [
            // Written for a different origin.
            OAuthConfiguration(
                origin: URL(string: "https://evil.test.invalid")!,
                server: OAuthServerMetadata(
                    issuer: "https://evil.test.invalid/api/auth",
                    authorizationEndpoint: URL(string: "https://evil.test.invalid/authorize")!,
                    tokenEndpoint: URL(string: "https://evil.test.invalid\(AuthFixtures.tokenPath)")!
                ),
                resource: "https://evil.test.invalid/api/v1",
                scopes: []
            ),
            // Right origin, but the token endpoint points elsewhere.
            OAuthConfiguration(
                origin: AuthFixtures.origin,
                server: OAuthServerMetadata(
                    issuer: "https://mail.test.invalid/api/auth",
                    authorizationEndpoint: URL(string: "https://mail.test.invalid/authorize")!,
                    tokenEndpoint: URL(string: "https://evil.test.invalid\(AuthFixtures.tokenPath)")!
                ),
                resource: AuthFixtures.resource,
                scopes: []
            ),
        ]
    )
    func foreignPersistedConfigurationIsIgnored(foreign: OAuthConfiguration) async throws {
        let server = Self.noDiscoveryServer()
        let (store, _) = try Self.seededStore(persisted: foreign)
        let coordinator = AuthCoordinator(store: store, presenter: FakeAuthorizationPresenter.succeeding(), session: server.makeSession())

        let provider = try await coordinator.tokenProvider(for: Self.account)
        await #expect(throws: (any Error).self) { _ = try await provider.accessToken() }
        #expect(server.requests(path: AuthFixtures.tokenPath).isEmpty, "the refresh token was sent using a foreign document")
    }

    /// A persisted copy goes stale when the server moves its endpoints. Fails
    /// if an activation with the server reachable does not refresh it (and the
    /// next refresh does not use the fresh endpoints).
    @Test("a stale persisted configuration is refreshed when the server is reachable")
    func staleConfigurationIsRefreshed() async throws {
        let stale = OAuthConfiguration(
            origin: AuthFixtures.origin,
            server: OAuthServerMetadata(
                issuer: "https://mail.test.invalid/api/auth",
                authorizationEndpoint: URL(string: "https://mail.test.invalid/old/authorize")!,
                tokenEndpoint: URL(string: "https://mail.test.invalid/old/token")!
            ),
            resource: AuthFixtures.resource,
            scopes: []
        )
        let server = AuthFixtures.fullServer()
        let (store, _) = try Self.seededStore(persisted: stale)
        let coordinator = AuthCoordinator(store: store, presenter: FakeAuthorizationPresenter.succeeding(), session: server.makeSession())

        let provider = try await coordinator.tokenProvider(for: Self.account)
        #expect(try await Self.eventually {
            try store.oauthConfiguration(for: AuthFixtures.origin)?.server.tokenEndpoint.path == AuthFixtures.tokenPath
        }, "the persisted copy was never refreshed")

        _ = try await provider.accessToken()
        #expect(server.requests(path: "/old/token").isEmpty, "refreshed against the stale endpoint after rediscovery")
        #expect(server.requests(path: AuthFixtures.tokenPath).count == 1)
    }

    /// Fails if a sign-in does not persist its discovery (the next launch
    /// could not come up offline), or if sign-out leaves it behind — a server
    /// reinstalled before the user signs back in would be trusted with the old
    /// install's endpoints (see the #discovery-cache gotcha).
    @Test("sign-in persists discovery and sign-out evicts it")
    func signOutEvictsPersistedConfiguration() async throws {
        let server = AuthFixtures.fullServer()
        let store = KeychainAccountStore(secrets: InMemorySecretStore())
        let coordinator = AuthCoordinator(store: store, presenter: FakeAuthorizationPresenter.succeeding(), session: server.makeSession())

        let account = try await coordinator.addAccount(origin: AuthFixtures.origin)
        #expect(try store.oauthConfiguration(for: AuthFixtures.origin) != nil, "sign-in did not persist its discovery")

        try await coordinator.signOut(account)
        #expect(try store.oauthConfiguration(for: AuthFixtures.origin) == nil)
    }

    /// A refresh still in flight when the account is signed out (it retries
    /// after the sign-out cancels its discovery) must not rediscover the origin
    /// and spend the grant the sign-out just revoked. Fails without the
    /// sign-out generation: the refresh discovers the origin again and sends
    /// the refresh token.
    @Test("a provider built before a sign-out never rediscovers or refreshes after it")
    func providerFromBeforeSignOutIsInert() async throws {
        let server = AuthFixtures.fullServer()
        let (store, _) = try Self.seededStore(persisted: nil)
        let coordinator = AuthCoordinator(store: store, presenter: FakeAuthorizationPresenter.succeeding(), session: server.makeSession())

        let provider = try await coordinator.tokenProvider(for: Self.account)
        try await coordinator.signOut(Self.account)
        // A grant for the same id shows up again (another process, a leftover):
        // the OLD provider must still stay out of it.
        try store.setTokens(Self.expired, for: Self.account.id)

        await #expect(throws: (any Error).self) { _ = try await provider.accessToken() }
        #expect(server.requests(path: AuthFixtures.tokenPath).isEmpty, "a signed-out provider spent the refresh token")
        #expect(try store.tokens(for: Self.account.id) == Self.expired)
    }

    /// Audit W2 meets the sign-in flow: consent must not run when the account
    /// list cannot be written (the minted grant would have nowhere to go), and
    /// sign-out must not revoke an account it then cannot remove. Fails if
    /// either reaches the network first.
    @Test("an unreadable account list stops sign-in before consent and sign-out before revoking")
    func unreadableIndexStopsSignInAndSignOutEarly() async throws {
        let server = AuthFixtures.revokingServer()
        let secrets = InMemorySecretStore()
        let store = KeychainAccountStore(secrets: secrets)
        try store.setTokens(Self.expired, for: Self.account.id)
        try secrets.set(Data(#"{"version":2}"#.utf8), for: "accounts.index")
        let presenter = FakeAuthorizationPresenter.succeeding()
        let coordinator = AuthCoordinator(store: store, presenter: presenter, session: server.makeSession())

        await #expect(throws: AccountStoreError.indexUnreadable) {
            _ = try await coordinator.addAccount(origin: AuthFixtures.origin)
        }
        #expect(presenter.authorizationURLs.isEmpty, "consent ran for a sign-in that could not be saved")

        await #expect(throws: AccountStoreError.indexUnreadable) {
            try await coordinator.signOut(Self.account)
        }
        #expect(server.requests(path: AuthFixtures.revokePath).isEmpty, "revoked an account it could not remove")
        #expect(try store.tokens(for: Self.account.id) == Self.expired)
    }
}
