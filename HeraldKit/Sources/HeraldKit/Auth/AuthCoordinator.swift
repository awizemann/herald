import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "oauth")

/// Where a sign-in currently is.
///
/// Reported step by step so a sign-in that stops moving names its location — both
/// in the log and under the spinner. The wording stays neutral here; the app owns
/// the user-facing copy, so HeraldKit never has to know what the UI calls a step.
public nonisolated enum AuthStep: String, Sendable, Hashable, CaseIterable {
    /// Resolving the server's `.well-known` metadata.
    case discovering
    /// Reading the Keychain for an existing `client_id` for this origin.
    case checkingRegistration
    /// Dynamic client registration (first sign-in against this origin only).
    case registering
    /// The browser window is up and the user is consenting.
    case presenting
    /// Redeeming the authorization code at the token endpoint.
    case exchanging
    /// Writing the account and its tokens to the Keychain.
    case saving
}

/// Reports ``AuthStep`` transitions to the caller. Main-actor: the only consumer
/// is UI state.
public typealias AuthStepHandler = @MainActor @Sendable (AuthStep) -> Void

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

    /// The session every auth call uses unless one is injected.
    ///
    /// NOT `URLSession.shared`: its defaults are a 60s request timeout and a
    /// **7-day** resource timeout, so a server that accepts a connection and then
    /// says nothing would leave discovery or the token exchange hanging for the
    /// rest of the week with no way to tell the user anything. Auth is a handful
    /// of small documents on an interactive path — 15s per request, 30s for the
    /// whole thing, is generous.
    public static let defaultSession: URLSession = makeSession()

    /// Builds an auth-shaped session. Exposed so a test can shorten the deadlines
    /// rather than waiting them out.
    public static func makeSession(
        requestTimeout: TimeInterval = 15,
        resourceTimeout: TimeInterval = 30
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        // Auth documents are per-request truth; a cached discovery document or
        // token response is never what we want.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    public init(
        store: any AccountStore = KeychainAccountStore(),
        presenter: any AuthorizationPresenter = WebAuthenticationPresenter(),
        session: URLSession = AuthCoordinator.defaultSession
    ) {
        self.store = store
        self.presenter = presenter
        self.session = session
        self.discovery = OAuthDiscovery(session: session)
        self.registration = DynamicClientRegistration(session: session)
    }

    /// Synchronous account list. Prefer ``loadAccounts()`` on any path that can
    /// await — this one runs `SecItemCopyMatching` on the caller's thread.
    public func accounts() throws -> [Account] { try store.accounts() }

    /// ``accounts()`` off the main actor, for the launch path.
    public func loadAccounts() async throws -> [Account] {
        try await offMain { [store] in try store.accounts() }
    }

    /// discovery → registration (reused when this origin already has a `client_id`)
    /// → PKCE → web authorization → code exchange → persist.
    ///
    /// - Parameter onStep: called on the main actor as each step begins, so the UI
    ///   can name where a slow sign-in is and the log can say where a stuck one
    ///   stopped. Default: report nothing.
    @discardableResult
    public func addAccount(
        origin rawOrigin: URL,
        onStep: @escaping AuthStepHandler = { _ in }
    ) async throws -> Account {
        let origin = Account.normalize(rawOrigin)
        let step = { (step: AuthStep) in
            logger.info("sign-in step: \(step.rawValue, privacy: .public)")
            onStep(step)
        }

        let configuration = try await configuration(for: origin, step: step)
        let clientID = try await clientID(for: origin, configuration: configuration, step: step)

        let oauth = OAuthSession(configuration: configuration, clientID: clientID, session: session)
        let request = oauth.makeAuthorizationRequest()
        step(.presenting)
        let callback = try await presenter.authorize(
            url: request.url,
            callbackScheme: DynamicClientRegistration.callbackScheme
        )
        let code = try oauth.authorizationCode(from: callback, for: request)
        step(.exchanging)
        let tokens = try await oauth.exchange(code: code, pkce: request.pkce)

        let account = Account(
            origin: origin,
            clientID: clientID,
            scopes: tokens.scopes.isEmpty ? configuration.scopes : tokens.scopes
        )
        step(.saving)
        try await offMain { [store] in
            try store.add(account)
            try store.setTokens(tokens, for: account.id)
        }
        logger.info("added account for \(origin.absoluteString, privacy: .public)")
        return account
    }

    /// Runs a synchronous ``AccountStore`` call off the main actor.
    ///
    /// `AccountStore` is a deliberately SYNCHRONOUS `nonisolated protocol` whose
    /// Keychain implementation serializes with `os_unfair_lock` (see "Herald
    /// Concurrency Rules"), and the `AccountTokenProvider` actor plus every test
    /// fake depend on that shape — so the fix for "a stalled `securityd` freezes
    /// the app" belongs at the CALL sites, not in a rewrite of the store into an
    /// actor. Detaching here keeps the main actor free to draw and to honour a
    /// cancel while `SecItemCopyMatching` is blocked.
    ///
    /// A blocked `SecItem` call cannot be interrupted by anything, detached or
    /// not, so cancellation does not shorten it — what this buys is that the
    /// stall happens on a background thread, so the window keeps drawing and the
    /// UI can abandon the attempt (``AppEnvironment/cancelSignIn()``) instead of
    /// beachballing behind it.
    private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }

    /// Forgets Herald's tokens for the account. The shared web session the browser
    /// holds is not ours to clear — see ``WebAuthenticationPresenter``.
    /// Revocation is best effort and happens BEFORE the local removal: dropping
    /// the tokens first would leave a live refresh token on the server that
    /// nothing can ever revoke. A failure is logged and removal proceeds anyway —
    /// the user asked to sign out.
    public func signOut(_ account: Account) async throws {
        await revokeRefreshToken(for: account)
        let accountID = account.id
        try await offMain { [store] in try store.remove(accountID) }
        // Keyed by the ORIGIN, exactly as `configuration(for:)` writes it. Keying
        // the eviction by `account.id` left the entry in place, so a server
        // reinstalled between a sign-out and a re-add in the same launch would
        // have been signed into with the PREVIOUS install's endpoints.
        configurations[cacheKey(account.origin)] = nil
        logger.info("signed out \(account.origin.absoluteString, privacy: .public)")
    }

    /// RFC 7009. Silently skipped when the server publishes no
    /// `revocation_endpoint`, or when there is no refresh token to revoke.
    private func revokeRefreshToken(for account: Account) async {
        let accountID = account.id
        guard let refreshToken = try? await offMain({ [store] in
            try store.tokens(for: accountID)?.refreshToken
        }) else { return }
        guard let configuration = try? await configuration(for: account.origin),
              let endpoint = configuration.server.revocationEndpoint
        else { return }
        do {
            let response = try await OAuthHTTP.postForm(
                endpoint,
                fields: [
                    ("token", refreshToken),
                    ("token_type_hint", "refresh_token"),
                    ("client_id", account.clientID),
                ],
                using: session
            )
            guard (200..<300).contains(response.status) else {
                logger.warning("revocation returned HTTP \(response.status); signing out locally anyway")
                return
            }
        } catch {
            logger.warning("revocation request failed; signing out locally anyway")
        }
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

    private nonisolated func cacheKey(_ origin: URL) -> String {
        Account.normalize(origin).absoluteString
    }

    private func configuration(
        for origin: URL,
        step: (AuthStep) -> Void = { _ in }
    ) async throws -> OAuthConfiguration {
        let key = cacheKey(origin)
        // Reported only when discovery actually runs: a re-auth reuses this
        // launch's cached document and does no I/O, and a stage that names a step
        // nothing is doing is worse than no stage at all.
        if let cached = configurations[key] { return cached }
        step(.discovering)
        let resolved = try await discovery.configuration(for: origin)
        configurations[key] = resolved
        return resolved
    }

    /// Registration happens at most once per origin; the id is read back from the
    /// Keychain on every later sign-in.
    private func clientID(
        for origin: URL,
        configuration: OAuthConfiguration,
        step: (AuthStep) -> Void = { _ in }
    ) async throws -> String {
        step(.checkingRegistration)
        let existing = try await offMain { [store] in try store.clientID(for: origin) }
        if let existing, !existing.isEmpty { return existing }
        guard let endpoint = configuration.server.registrationEndpoint else {
            logger.error("\(origin.absoluteString, privacy: .public) has no registration_endpoint")
            throw OAuthError.registrationUnsupported
        }
        step(.registering)
        let clientID = try await registration.register(
            at: endpoint,
            resource: configuration.resource,
            scopes: configuration.scopes
        )
        try await offMain { [store] in try store.setClientID(clientID, for: origin) }
        return clientID
    }
}
