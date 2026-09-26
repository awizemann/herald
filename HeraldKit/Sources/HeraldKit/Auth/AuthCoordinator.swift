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

    /// Discovery results fetched LIVE this launch. Endpoints are stable, and
    /// re-running discovery on every token refresh would double the request
    /// count. Only live results land here — never the persisted copy — so a
    /// sign-in (``addAccount(origin:onStep:)``) always runs against endpoints
    /// the server confirmed this launch.
    private var configurations: [String: OAuthConfiguration] = [:]

    /// The background discovery running for an origin, if any (see
    /// ``discoverInBackground(_:)``). Cleared by ``signOut(_:)`` so a result that
    /// lands after the sign-out is dropped.
    private var discoveries: [String: Task<OAuthConfiguration, any Error>] = [:]

    /// Bumped by every ``signOut(_:)`` of an origin. A provider remembers the
    /// value it was built under, and its refreshes refuse to resolve endpoints
    /// once it has moved: otherwise a refresh still in flight at sign-out
    /// (retrying the discovery the sign-out cancelled) would start a NEW
    /// discovery and put back the cache the sign-out just evicted — then spend
    /// the refresh token it just revoked.
    private var signOutGenerations: [String: Int] = [:]

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
        // BEFORE the browser: an account list the store will refuse to write
        // (`AccountStoreError.indexUnreadable`) must stop the sign-in here, not
        // after consent has minted a grant that then has nowhere to go. Covers
        // re-auth too, which the app's own Add Account check does not.
        try await offMain { [store] in _ = try store.accounts() }

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
            // What lets the NEXT launch bring this account up with no network.
            // Not fatal: without it activation discovers lazily instead.
            do {
                try store.setOAuthConfiguration(configuration, for: origin)
            } catch {
                logger.warning("could not persist discovery for \(origin.absoluteString, privacy: .public)")
            }
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
        // BEFORE revoking: an account list the store refuses to rewrite would
        // leave the account in it with a grant the server no longer honours.
        try await offMain { [store] in _ = try store.accounts() }
        await revokeRefreshToken(for: account)
        let accountID = account.id
        let origin = Account.normalize(account.origin)
        // Keyed by the ORIGIN, exactly as `configuration(for:)` writes it. Keying
        // the eviction by `account.id` left the entry in place, so a server
        // reinstalled between a sign-out and a re-add in the same launch would
        // have been signed into with the PREVIOUS install's endpoints. The
        // persisted copy goes too (below), for the same reason across launches,
        // and a background discovery still in flight is disowned so its result
        // cannot put either back.
        let key = cacheKey(origin)
        signOutGenerations[key, default: 0] += 1
        configurations[key] = nil
        discoveries.removeValue(forKey: key)?.cancel()
        try await offMain { [store] in
            // Evicted even when the removal throws: it is only a cache.
            defer {
                do {
                    try store.setOAuthConfiguration(nil, for: origin)
                } catch {
                    logger.warning("could not evict persisted discovery for \(origin.absoluteString, privacy: .public)")
                }
            }
            try store.remove(accountID)
        }
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
    ///
    /// Does NO network I/O, so an account comes up — cached mail readable — with
    /// the server unreachable (audit W4: activation used to run discovery here,
    /// and an offline launch ended on "Herald could not start"). The endpoints
    /// are resolved when a refresh actually needs them
    /// (``refreshConfiguration(for:fallback:generation:)``): this launch's live discovery
    /// if there is one, else the copy persisted at sign-in, else a live
    /// discovery awaited then. A background discovery started here keeps the
    /// persisted copy fresh whenever the server is reachable.
    ///
    /// Still `throws` for source compatibility; it no longer fails.
    public func tokenProvider(for account: Account) async throws -> AccountTokenProvider {
        let origin = Account.normalize(account.origin)
        let generation = signOutGenerations[cacheKey(origin), default: 0]
        var fallback: OAuthConfiguration?
        if configurations[cacheKey(origin)] == nil {
            fallback = await persistedConfiguration(for: origin)
            // Re-checked: the read above suspended.
            if configurations[cacheKey(origin)] == nil { _ = discoverInBackground(origin) }
        }
        return AccountTokenProvider(
            accountID: account.id,
            store: store,
            refresher: DiscoveringRefresher(clientID: account.clientID, session: session) { [self, fallback] in
                try await self.refreshConfiguration(for: origin, fallback: fallback, generation: generation)
            }
        )
    }

    /// The endpoints a refresh uses. See ``tokenProvider(for:)``.
    ///
    /// With a persisted copy in hand it never WAITS on the network: a server that
    /// accepts connections and then says nothing would otherwise hold every
    /// refresh on discovery's timeouts. It starts (or joins) a background
    /// discovery instead, whose result the next refresh uses — which is also how
    /// a stale copy (the server moved its endpoints) heals once the server is
    /// reachable.
    ///
    /// - Parameter generation: the origin's sign-out generation the provider was
    ///   built under. Once the origin has been signed out since, this throws
    ///   (``OAuthError/unknownAccount(_:)``, not retryable) instead of
    ///   rediscovering for an account that is gone.
    func refreshConfiguration(
        for origin: URL,
        fallback: OAuthConfiguration?,
        generation: Int
    ) async throws -> OAuthConfiguration {
        guard signOutGenerations[cacheKey(origin), default: 0] == generation else {
            logger.info("refresh for a signed-out origin refused: \(origin.absoluteString, privacy: .public)")
            throw OAuthError.unknownAccount(origin.absoluteString)
        }
        if let live = configurations[cacheKey(origin)] { return live }
        let pending = discoverInBackground(origin)
        if let fallback { return fallback }
        return try await pending.value
    }

    /// Starts (or joins) a live discovery for `origin` that fills this launch's
    /// cache and refreshes the persisted copy.
    ///
    /// Persisted only while an account for the origin is still in the index: a
    /// sign-out that lands meanwhile disowns the task (its result is dropped),
    /// and the index check keeps a late write from resurrecting a copy for an
    /// origin nobody is signed in to.
    private func discoverInBackground(_ origin: URL) -> Task<OAuthConfiguration, any Error> {
        let key = cacheKey(origin)
        if let running = discoveries[key] { return running }
        let task = Task { [discovery] in try await discovery.configuration(for: origin) }
        discoveries[key] = task
        Task { [weak self] in
            let result = await task.result
            guard let self, self.discoveries[key] == task else { return }
            self.discoveries[key] = nil
            guard case .success(let configuration) = result else {
                logger.info("background discovery failed for \(origin.absoluteString, privacy: .public); will retry on the next refresh")
                return
            }
            self.configurations[key] = configuration
            do {
                try await self.offMain { [store, key] in
                    let signedIn = try store.accounts().contains { Account.normalize($0.origin).absoluteString == key }
                    guard signedIn else { return }
                    try store.setOAuthConfiguration(configuration, for: origin)
                }
            } catch {
                logger.warning("could not persist discovery for \(origin.absoluteString, privacy: .public)")
            }
        }
        return task
    }

    /// The copy persisted at the last successful discovery, if it is usable for
    /// THIS origin. Anything else — unreadable, for another origin, pointing
    /// off-origin — is a miss, never an error: discovery just runs again.
    private func persistedConfiguration(for origin: URL) async -> OAuthConfiguration? {
        let stored: OAuthConfiguration?
        do {
            stored = try await offMain { [store] in try store.oauthConfiguration(for: origin) }
        } catch {
            logger.warning("persisted discovery unreadable for \(origin.absoluteString, privacy: .public); will rediscover")
            return nil
        }
        guard let stored else { return nil }
        guard cacheKey(stored.origin) == cacheKey(origin),
              OAuthDiscovery.endpointsAreTrusted(stored.server, for: origin)
        else {
            logger.error("persisted discovery does not match \(origin.absoluteString, privacy: .public); ignoring it")
            return nil
        }
        return stored
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

/// A ``TokenRefreshing`` that resolves its endpoints at refresh time rather than
/// at construction, so building the token provider needs no network. See
/// ``AuthCoordinator/tokenProvider(for:)``.
nonisolated struct DiscoveringRefresher: TokenRefreshing {
    let clientID: String
    let session: URLSession
    let resolve: @Sendable () async throws -> OAuthConfiguration

    func refresh(refreshToken: String) async throws -> OAuthTokens {
        let configuration = try await resolve()
        return try await OAuthSession(configuration: configuration, clientID: clientID, session: session)
            .refresh(refreshToken: refreshToken)
    }
}
