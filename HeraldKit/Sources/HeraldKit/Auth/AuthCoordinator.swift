import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "oauth")

/// App-facing entry point for signing in and out.
///
/// `@MainActor` (the package default) because it is driven by UI and owns only a
/// small metadata cache; every call it makes suspends immediately into `URLSession`
/// or the presenter, so nothing blocking runs on main.
public final class AuthCoordinator {
    private let store: any AccountStore
    private let presenter: any AuthorizationPresenter
    private let discovery: OAuthDiscovery
    private let registration: DynamicClientRegistration
    private let session: URLSession

    /// Discovery results for this launch. Endpoints are stable, and re-running
    /// discovery on every token refresh would double the request count.
    private var configurations: [String: OAuthConfiguration] = [:]

    public init(
        store: any AccountStore = KeychainAccountStore(),
        presenter: any AuthorizationPresenter = WebAuthenticationPresenter(),
        session: URLSession = .shared
    ) {
        self.store = store
        self.presenter = presenter
        self.session = session
        self.discovery = OAuthDiscovery(session: session)
        self.registration = DynamicClientRegistration(session: session)
    }

    public func accounts() throws -> [Account] { try store.accounts() }

    /// discovery → registration (reused when this origin already has a `client_id`)
    /// → PKCE → web authorization → code exchange → persist.
    @discardableResult
    public func addAccount(origin rawOrigin: URL) async throws -> Account {
        let origin = Account.normalize(rawOrigin)
        let configuration = try await configuration(for: origin)
        let clientID = try await clientID(for: origin, configuration: configuration)

        let oauth = OAuthSession(configuration: configuration, clientID: clientID, session: session)
        let request = oauth.makeAuthorizationRequest()
        let callback = try await presenter.authorize(
            url: request.url,
            callbackScheme: DynamicClientRegistration.callbackScheme
        )
        let code = try oauth.authorizationCode(from: callback, for: request)
        let tokens = try await oauth.exchange(code: code, pkce: request.pkce)

        let account = Account(
            origin: origin,
            clientID: clientID,
            scopes: tokens.scopes.isEmpty ? configuration.scopes : tokens.scopes
        )
        try store.add(account)
        try store.setTokens(tokens, for: account.id)
        logger.info("added account for \(origin.absoluteString, privacy: .public)")
        return account
    }

    /// Forgets Herald's tokens for the account. The shared web session the browser
    /// holds is not ours to clear — see ``WebAuthenticationPresenter``.
    public func signOut(_ account: Account) throws {
        try store.remove(account.id)
        configurations[account.id] = nil
        logger.info("signed out \(account.origin.absoluteString, privacy: .public)")
    }

    /// The provider ``HQBaseAPIClient`` is constructed with.
    public func tokenProvider(for account: Account) async throws -> AccountTokenProvider {
        let configuration = try await configuration(for: account.origin)
        return AccountTokenProvider(
            accountID: account.id,
            store: store,
            refresher: OAuthSession(
                configuration: configuration,
                clientID: account.clientID,
                session: session
            )
        )
    }

    // MARK: - Steps

    private func configuration(for origin: URL) async throws -> OAuthConfiguration {
        let key = Account.normalize(origin).absoluteString
        if let cached = configurations[key] { return cached }
        let resolved = try await discovery.configuration(for: origin)
        configurations[key] = resolved
        return resolved
    }

    /// Registration happens at most once per origin; the id is read back from the
    /// Keychain on every later sign-in.
    private func clientID(for origin: URL, configuration: OAuthConfiguration) async throws -> String {
        if let existing = try store.clientID(for: origin), !existing.isEmpty { return existing }
        guard let endpoint = configuration.server.registrationEndpoint else {
            logger.error("\(origin.absoluteString, privacy: .public) has no registration_endpoint")
            throw OAuthError.registrationUnsupported
        }
        let clientID = try await registration.register(
            at: endpoint,
            resource: configuration.resource,
            scopes: configuration.scopes
        )
        try store.setClientID(clientID, for: origin)
        return clientID
    }
}
