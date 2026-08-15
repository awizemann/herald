import Foundation
import Testing
@testable import HeraldKit

@Suite struct AuthCoordinatorTests {
    /// End-to-end happy path over ``FakeServer``: discovery, registration, PKCE,
    /// presenter, exchange, persist. Fails if any step is skipped or wired to the
    /// wrong endpoint.
    @Test("addAccount runs discovery, registration and exchange and persists tokens")
    func addAccountHappyPath() async throws {
        let server = AuthFixtures.fullServer()
        let store = RecordingAccountStore()
        let presenter = FakeAuthorizationPresenter.succeeding()
        let coordinator = AuthCoordinator(store: store, presenter: presenter, session: server.makeSession())

        let account = try await coordinator.addAccount(origin: URL(string: "https://mail.test.invalid/")!)

        #expect(account.origin.absoluteString == "https://mail.test.invalid")
        #expect(account.clientID == "cid_registered")
        #expect(account.label == "mail.test.invalid")
        #expect(account.resource == AuthFixtures.resource)
        #expect(try store.accounts().map(\.id) == [account.id])
        #expect(try store.tokens(for: account.id)?.accessToken == "hqb_access_1")
        #expect(try store.clientID(for: AuthFixtures.origin) == "cid_registered")

        // The presenter got the real authorize URL, and the exchange used its verifier.
        let authorizeURL = try #require(presenter.authorizationURLs.first)
        let query = AuthFixtures.query(authorizeURL)
        #expect(query["resource"] == AuthFixtures.resource)
        let exchange = AuthFixtures.form(try #require(server.requests(path: AuthFixtures.tokenPath).first).bodyText)
        #expect(exchange["code"] == "auth_code_1")
        #expect(exchange["code_verifier"] != nil)
        #expect(PKCE.challenge(for: exchange["code_verifier"]!) == query["code_challenge"])
    }

    /// Fails if the coordinator re-registers on every sign-in: HQBase would accrue a
    /// new `oauthClient` row per launch and the user would re-consent each time.
    @Test("an origin with a stored client_id is not registered again")
    func registrationIsSkippedWhenClientIDExists() async throws {
        let server = AuthFixtures.fullServer()
        let store = RecordingAccountStore(clientIDs: ["https://mail.test.invalid": "cid_existing"])
        let coordinator = AuthCoordinator(
            store: store,
            presenter: FakeAuthorizationPresenter.succeeding(),
            session: server.makeSession()
        )

        let account = try await coordinator.addAccount(origin: AuthFixtures.origin)

        #expect(account.clientID == "cid_existing")
        #expect(server.requests(path: AuthFixtures.registerPath).isEmpty, "re-registered despite a stored client_id")
        let exchange = AuthFixtures.form(try #require(server.requests(path: AuthFixtures.tokenPath).first).bodyText)
        #expect(exchange["client_id"] == "cid_existing")
    }

    /// Fails if a forged or stale callback still gets redeemed.
    @Test("a callback with a mismatched state aborts before the token endpoint")
    func mismatchedCallbackAborts() async throws {
        let server = AuthFixtures.fullServer()
        let store = RecordingAccountStore()
        let coordinator = AuthCoordinator(
            store: store,
            presenter: FakeAuthorizationPresenter { _ in
                URL(string: "herald://oauth/callback?code=stolen&state=attacker")!
            },
            session: server.makeSession()
        )

        await #expect(throws: OAuthError.stateMismatch) {
            _ = try await coordinator.addAccount(origin: AuthFixtures.origin)
        }
        #expect(server.requests(path: AuthFixtures.tokenPath).isEmpty)
        #expect(try store.accounts().isEmpty)
    }

    /// Fails if a server with no `registration_endpoint` produces a crash or a
    /// confusing transport error instead of an actionable one.
    @Test("a server without registration_endpoint throws .registrationUnsupported")
    func registrationUnsupported() async throws {
        let server = FakeServer()
        server.route("GET", AuthFixtures.protectedResourcePath, .json(200, AuthFixtures.protectedResourceJSON))
        server.route("GET", AuthFixtures.suffixedMetadataPath, .json(200, """
        {"issuer":"https://mail.test.invalid/api/auth",
         "authorization_endpoint":"https://mail.test.invalid\(AuthFixtures.authorizePath)",
         "token_endpoint":"https://mail.test.invalid\(AuthFixtures.tokenPath)"}
        """))

        let coordinator = AuthCoordinator(
            store: RecordingAccountStore(),
            presenter: FakeAuthorizationPresenter.succeeding(),
            session: server.makeSession()
        )

        await #expect(throws: OAuthError.registrationUnsupported) {
            _ = try await coordinator.addAccount(origin: AuthFixtures.origin)
        }
    }

    /// Fails if the discovered configuration is thrown away and re-fetched on every
    /// call — sync builds a token provider per account and would double every
    /// launch's `.well-known` traffic.
    @Test("discovery runs once per origin across addAccount and tokenProvider(for:)")
    func discoveryIsCached() async throws {
        let server = AuthFixtures.fullServer()
        let coordinator = AuthCoordinator(
            store: RecordingAccountStore(),
            presenter: FakeAuthorizationPresenter.succeeding(),
            session: server.makeSession()
        )

        let account = try await coordinator.addAccount(origin: AuthFixtures.origin)
        _ = try await coordinator.tokenProvider(for: account)
        _ = try await coordinator.tokenProvider(for: account)

        #expect(server.requests(path: AuthFixtures.suffixedMetadataPath).count == 1)
        #expect(server.requests(path: AuthFixtures.protectedResourcePath).count == 1)
    }

    /// Fails if sign-out leaves tokens behind, or if it also wipes the registration
    /// (which would force a pointless re-register when the user signs back in).
    @Test("signOut drops the account and its tokens but keeps the client registration")
    func signOutClearsTokensNotRegistration() async throws {
        let server = AuthFixtures.fullServer()
        let store = RecordingAccountStore()
        let coordinator = AuthCoordinator(
            store: store,
            presenter: FakeAuthorizationPresenter.succeeding(),
            session: server.makeSession()
        )

        let account = try await coordinator.addAccount(origin: AuthFixtures.origin)
        try await coordinator.signOut(account)

        #expect(try store.accounts().isEmpty)
        #expect(try store.tokens(for: account.id) == nil)
        #expect(try store.clientID(for: AuthFixtures.origin) == "cid_registered")
        // This server advertises no revocation_endpoint: skip it, do not fail.
        #expect(server.requests(path: AuthFixtures.revokePath).isEmpty)
    }

    /// Signing out used to only forget Herald's copy of the tokens: the refresh
    /// token stayed live on the server for its whole lifetime, redeemable by
    /// anyone who had captured it. Fails on a sign-out that does not revoke, that
    /// revokes the access token instead of the refresh token, or that revokes
    /// AFTER dropping the tokens (at which point there is nothing left to send).
    @Test("signOut revokes the refresh token before dropping it")
    func signOutRevokesTheRefreshToken() async throws {
        let server = AuthFixtures.revokingServer()
        let store = RecordingAccountStore()
        let coordinator = AuthCoordinator(
            store: store,
            presenter: FakeAuthorizationPresenter.succeeding(),
            session: server.makeSession()
        )

        let account = try await coordinator.addAccount(origin: AuthFixtures.origin)
        try await coordinator.signOut(account)

        let revocation = try #require(server.requests(path: AuthFixtures.revokePath).first)
        let fields = AuthFixtures.form(revocation.bodyText)
        #expect(fields["token"] == "hqb_refresh_1")
        #expect(fields["token_type_hint"] == "refresh_token")
        #expect(fields["client_id"] == "cid_registered")
        #expect(try store.tokens(for: account.id) == nil)
    }

    /// Fails if a server that rejects (or cannot answer) the revocation traps the
    /// user in a signed-in state they explicitly asked to leave.
    @Test("a failed revocation still signs the account out locally")
    func failedRevocationStillSignsOut() async throws {
        let server = AuthFixtures.revokingServer(
            revocation: .error(500, code: "boom", message: "revocation is down")
        )
        let store = RecordingAccountStore()
        let coordinator = AuthCoordinator(
            store: store,
            presenter: FakeAuthorizationPresenter.succeeding(),
            session: server.makeSession()
        )

        let account = try await coordinator.addAccount(origin: AuthFixtures.origin)
        try await coordinator.signOut(account)

        #expect(server.requests(path: AuthFixtures.revokePath).count == 1)
        #expect(try store.accounts().isEmpty)
        #expect(try store.tokens(for: account.id) == nil)
    }

    /// The provider handed to ``HQBaseAPIClient`` must be able to refresh against the
    /// real token endpoint. Fails if it is built with the wrong client id or origin.
    @Test("tokenProvider(for:) refreshes against the discovered token endpoint")
    func tokenProviderRefreshes() async throws {
        let server = AuthFixtures.fullServer()
        let store = RecordingAccountStore()
        let coordinator = AuthCoordinator(
            store: store,
            presenter: FakeAuthorizationPresenter.succeeding(),
            session: server.makeSession()
        )

        let account = try await coordinator.addAccount(origin: AuthFixtures.origin)
        let provider = try await coordinator.tokenProvider(for: account)
        #expect(try await provider.refreshAccessToken(failedToken: "hqb_access_1") == "hqb_access_1")

        let refresh = try #require(server.requests(path: AuthFixtures.tokenPath).last)
        let fields = AuthFixtures.form(refresh.bodyText)
        #expect(fields["grant_type"] == "refresh_token")
        #expect(fields["client_id"] == "cid_registered")
        #expect(fields["resource"] == AuthFixtures.resource)
    }
}
