import Foundation
import Testing
@testable import HeraldKit

/// A saved registration is reused only while its scopes cover what Herald asks
/// for. HQBase refuses an authorize request for any scope the client did not
/// register (`invalid_scope`), so a registration made before Herald adopted a
/// scope (1.4.2's `signatures:manage`) could never sign in again — every retry
/// reused it and failed the same way.
@Suite("Registration scope coverage")
struct RegistrationScopeTests {
    private static let origin = AuthFixtures.origin
    /// What ``AuthFixtures/fullServer()`` advertises, plus `offline_access`.
    private static let requested = ["mail:read", "mail:write", "mail:send", "offline_access"]

    /// Fails if a registration with no recorded scopes (what every pre-fix build
    /// left in the Keychain) is reused instead of replaced.
    @Test("a registration with unknown scopes is replaced, and the new scopes are recorded")
    @MainActor func legacyRegistrationIsReplaced() async throws {
        let server = AuthFixtures.fullServer()
        let store = KeychainAccountStore(secrets: InMemorySecretStore())
        try store.setClientID("cid_legacy", for: Self.origin)
        let coordinator = AuthCoordinator(store: store, presenter: FakeAuthorizationPresenter.succeeding(), session: server.makeSession())

        let account = try await coordinator.addAccount(origin: Self.origin)

        #expect(server.requests(path: AuthFixtures.registerPath).count == 1)
        #expect(account.clientID == "cid_registered")
        #expect(try store.clientID(for: Self.origin) == "cid_registered")
        #expect(try store.clientScopes(for: Self.origin) == Self.requested)
    }

    /// Fails if a registration missing a scope Herald now asks for is reused.
    @Test("a registration missing a requested scope is replaced")
    @MainActor func narrowerRegistrationIsReplaced() async throws {
        let server = AuthFixtures.fullServer()
        let store = KeychainAccountStore(secrets: InMemorySecretStore())
        try store.setClientID("cid_narrow", scopes: ["mail:read", "mail:write", "offline_access"], for: Self.origin)
        let coordinator = AuthCoordinator(store: store, presenter: FakeAuthorizationPresenter.succeeding(), session: server.makeSession())

        let account = try await coordinator.addAccount(origin: Self.origin)

        #expect(server.requests(path: AuthFixtures.registerPath).count == 1)
        #expect(account.clientID == "cid_registered")
    }

    /// Guards the other direction: a covering registration must NOT churn.
    @Test("a registration covering every requested scope is reused")
    @MainActor func coveringRegistrationIsReused() async throws {
        let server = AuthFixtures.fullServer()
        let store = KeychainAccountStore(secrets: InMemorySecretStore())
        try store.setClientID("cid_wide", scopes: Self.requested + ["signatures:manage"], for: Self.origin)
        let coordinator = AuthCoordinator(store: store, presenter: FakeAuthorizationPresenter.succeeding(), session: server.makeSession())

        let account = try await coordinator.addAccount(origin: Self.origin)

        #expect(server.requests(path: AuthFixtures.registerPath).isEmpty)
        #expect(account.clientID == "cid_wide")
    }

    /// The exact failure from the field: the server redirects back with
    /// `invalid_scope` and a form-encoded description. Fails if the registration
    /// survives (every later sign-in would fail the same way) or if the
    /// description keeps its `+` signs.
    @Test("an invalid_scope callback forgets the registration and decodes the description")
    @MainActor func invalidScopeForgetsRegistration() async throws {
        let server = AuthFixtures.fullServer()
        let store = KeychainAccountStore(secrets: InMemorySecretStore())
        try store.setClientID("cid_wide", scopes: Self.requested, for: Self.origin)
        let presenter = FakeAuthorizationPresenter { url in
            let state = AuthFixtures.query(url)["state"] ?? ""
            return URL(string: "com.wizemann.herald:/oauth/callback?error=invalid_scope&error_description=The+following+scopes+are+invalid:+signatures%3Amanage&state=\(state)")!
        }
        let coordinator = AuthCoordinator(store: store, presenter: presenter, session: server.makeSession())

        await #expect(throws: OAuthError.scopesRefused(description: "The following scopes are invalid: signatures:manage")) {
            try await coordinator.addAccount(origin: Self.origin)
        }
        #expect(try store.clientID(for: Self.origin) == nil)
        #expect(try store.clientScopes(for: Self.origin) == nil)
        #expect(try store.accounts().isEmpty)
    }

    /// The `+` decoding must not mangle the success path: a code with an
    /// encoded `+` still arrives intact.
    @Test("callback values are form-decoded")
    func callbackFormDecoding() throws {
        let configuration = AuthFixtures.configuration
        let oauth = OAuthSession(configuration: configuration, clientID: "cid", session: URLSession(configuration: .ephemeral))
        let request = oauth.makeAuthorizationRequest()
        let callback = URL(string: "com.wizemann.herald:/oauth/callback?code=a%2Bb&state=\(request.state)")!

        #expect(try oauth.authorizationCode(from: callback, for: request) == "a+b")
    }
}
