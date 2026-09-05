import Foundation
import HeraldKit
import Testing
@testable import Herald

/// Herald #9: sign-in wedged with a spinner, no browser window, no way out — the
/// onboarding screen kept no handle on the work and offered no Cancel, so the only
/// escape was force-quitting Herald.
///
/// These drive `AppEnvironment` through the shapes that hang and assert the two
/// things that make a hang survivable: it NAMES where it is, and it can be
/// abandoned.
@MainActor
@Suite struct SignInRecoveryTests {
    static let origin = "https://mail.test.invalid"

    // MARK: - The reported wedge

    /// The reproduction of the report: a browser session that starts and never
    /// reports anything. Fails if the spinner is up with nothing said about it —
    /// the stage is what turns "it's stuck" into "it's stuck waiting for the
    /// sign-in window", which is what the log and the caption now show.
    @Test("a presenter that never answers leaves the spinner at the browser step")
    func pendingPresenterIsVisibleAtTheBrowserStep() async throws {
        let environment = Self.environment(presenter: PendingPresenter())
        let attempt = Task { await environment.signIn(originText: Self.origin) }
        defer { attempt.cancel() }

        try await wait("the sign-in to reach the browser hand-off") {
            environment.isSigningIn && environment.signInStage == .waitingForBrowser
        }

        #expect(environment.isSigningIn)
        #expect(environment.signInStage == .waitingForBrowser)
        #expect(environment.signInError == nil)

        // And it stays there — this is the hang, not a slow step.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(environment.isSigningIn)

        environment.cancelSignIn()
    }

    /// The recovery. Fails if cancelling only closes a window (the old `dismiss()`
    /// wiring, which did nothing at all on the first-run screen), or if the
    /// abandoned attempt leaves state behind that blocks the next one.
    @Test("cancelSignIn clears the state and a second attempt runs")
    func cancelClearsStateAndAllowsASecondAttempt() async throws {
        let presenter = ScriptedPresenter()
        let store = InMemoryAccountStore()
        let environment = Self.environment(presenter: presenter, store: store)

        let first = Task { await environment.signIn(originText: Self.origin) }
        try await wait("the first attempt to reach the browser hand-off") {
            environment.signInStage == .waitingForBrowser
        }

        environment.cancelSignIn()

        // Immediately usable again — not "once the dead attempt gives up".
        #expect(environment.isSigningIn == false)
        #expect(environment.signInStage == nil)
        #expect(environment.signInError == nil)
        _ = await first.value

        presenter.completeNextAttempt()
        await environment.signIn(originText: Self.origin)

        #expect(presenter.attemptCount == 2, "the second attempt never reached the presenter")
        #expect(environment.isSigningIn == false)
        // The account really was added: the second round trip ran the whole flow.
        #expect(try store.accounts().isEmpty == false)
    }

    /// Fails if a cancelled attempt that later completes anyway (the authentication
    /// agent waking up after the user gave up) still installs its account and drags
    /// the user into a mailbox they walked away from.
    @Test("a sign-in that completes after being cancelled does not install")
    func lateCompletionAfterCancelDoesNotInstall() async throws {
        let presenter = ScriptedPresenter()
        let store = InMemoryAccountStore()
        let environment = Self.environment(presenter: presenter, store: store)

        let attempt = Task { await environment.signIn(originText: Self.origin) }
        try await wait("the attempt to reach the browser hand-off") {
            environment.signInStage == .waitingForBrowser
        }
        environment.cancelSignIn()
        // The browser answers AFTER the cancel.
        presenter.completeNextAttempt()
        _ = await attempt.value

        #expect(environment.isSigningIn == false)
        #expect(environment.signInStage == nil)
        #expect(environment.graphs.isEmpty, "a cancelled sign-in installed its account anyway")
        #expect(environment.presentsAddAccount == false)
        // And it is not merely deferred: `addAccount` had already written the
        // account and its tokens to the Keychain by the time the cancel was seen,
        // so leaving them would have restored the account on the NEXT launch.
        #expect(try store.accounts().isEmpty, "a cancelled sign-in left the account in the Keychain")
    }

    // MARK: - Where a hang can be

    /// A server that accepts the connection and never answers. Fails if the stage
    /// blames the browser (or says nothing) for what is actually a stuck server.
    @Test("a stalled server leaves the sign-in at the discovery stage")
    func stalledDiscoveryIsNamed() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StallingProtocol.self]
        configuration.timeoutIntervalForRequest = 30
        let environment = Self.environment(
            presenter: PendingPresenter(),
            session: URLSession(configuration: configuration)
        )

        let attempt = Task { await environment.signIn(originText: Self.origin) }
        defer { attempt.cancel() }

        try await wait("the sign-in to reach discovery") {
            environment.signInStage == .contactingServer
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(environment.signInStage == .contactingServer)

        environment.cancelSignIn()
    }

    /// The `securityd`-stall shape: a synchronous Keychain read that never
    /// returns. Fails if it runs on the main actor — the whole app would freeze
    /// (no repaint, no Cancel), which is the "app frozen" half of the diagnosis
    /// for issue #9 and was true of `clientID(for:)` as shipped in 0.4.0.
    @Test("a blocking Keychain read stalls off the main actor, which stays free")
    func blockingKeychainReadKeepsTheMainActorFree() async throws {
        let store = GatedAccountStore()
        let environment = Self.environment(presenter: PendingPresenter(), store: store)
        let attempt = Task { await environment.signIn(originText: Self.origin) }
        defer {
            store.open()
            attempt.cancel()
        }

        try await wait("the sign-in to reach the Keychain read") {
            environment.signInStage == .checkingRegistration
        }
        try await wait("the read to actually be in progress") { store.isBlocked }

        // Reaching here at all means main is running; time a round trip to say so
        // in a way that fails loudly rather than hanging the suite.
        let started = ContinuousClock.now
        await Task { @MainActor in }.value
        #expect(started.duration(to: .now) < .milliseconds(500), "the main actor was blocked by the Keychain read")
        #expect(environment.signInStage == .checkingRegistration)

        // And the user can still walk away from it.
        environment.cancelSignIn()
        #expect(environment.isSigningIn == false)
    }

    // MARK: - Harness

    static func environment(
        presenter: any AuthorizationPresenter,
        store: (any AccountStore)? = nil,
        session: URLSession? = nil
    ) -> AppEnvironment {
        let suite = "SignInRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppEnvironment(
            auth: AuthCoordinator(
                store: store ?? InMemoryAccountStore(),
                presenter: presenter,
                session: session ?? OAuthTestServer.session()
            ),
            defaults: defaults
        )
    }
}

// MARK: - Presenters

/// Starts and never reports anything, cancellation included — the wedged
/// authentication agent as the app sees it.
nonisolated final class PendingPresenter: AuthorizationPresenter {
    func authorize(url: URL, callbackScheme: String) async throws -> URL {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        fatalError("unreachable")
    }
}

/// Pends until told to answer, and honours cancellation the way
/// ``WebAuthenticationRunner`` does.
nonisolated final class ScriptedPresenter: AuthorizationPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private var completeImmediately = false

    var attemptCount: Int { lock.withLock { attempts } }

    /// The next `authorize` returns a valid callback instead of pending.
    func completeNextAttempt() { lock.withLock { completeImmediately = true } }

    func authorize(url: URL, callbackScheme: String) async throws -> URL {
        let answerNow = lock.withLock { () -> Bool in
            attempts += 1
            return completeImmediately
        }
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value ?? ""
        let callback = URL(string: "com.wizemann.herald:/oauth/callback?code=auth_code_1&state=\(state)")!
        if answerNow { return callback }

        // Pend until either cancelled or told to answer.
        while !Task.isCancelled {
            if lock.withLock({ completeImmediately }) { return callback }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw OAuthError.userCancelled
    }
}

// MARK: - Stores

/// Blocks inside `clientID(for:)` until opened — a `securityd` stall, reproduced
/// without one.
nonisolated final class GatedAccountStore: AccountStore, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var blocked = false
    private var opened = false
    private let backing = InMemoryAccountStore()

    var isBlocked: Bool { lock.withLock { blocked } }

    func open() {
        let shouldSignal = lock.withLock { () -> Bool in
            guard !opened else { return false }
            opened = true
            return true
        }
        if shouldSignal { gate.signal() }
    }

    func clientID(for origin: URL) throws -> String? {
        lock.withLock { blocked = true }
        gate.wait()
        lock.withLock { blocked = false }
        return try backing.clientID(for: origin)
    }

    func accounts() throws -> [Account] { try backing.accounts() }
    func add(_ account: Account) throws { try backing.add(account) }
    func remove(_ accountID: Account.ID) throws { try backing.remove(accountID) }
    func tokens(for accountID: Account.ID) throws -> OAuthTokens? { try backing.tokens(for: accountID) }
    func setTokens(_ tokens: OAuthTokens?, for accountID: Account.ID) throws {
        try backing.setTokens(tokens, for: accountID)
    }
    func setClientID(_ clientID: String, for origin: URL) throws { try backing.setClientID(clientID, for: origin) }
}

// MARK: - Servers

/// Accepts and never answers.
nonisolated final class StallingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

/// The smallest HQBase-shaped OAuth server: discovery, registration, token.
nonisolated enum OAuTestServerConstants {
    static let host = "mail.test.invalid"
}

nonisolated final class OAuthTestServer: URLProtocol, @unchecked Sendable {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthTestServer.self]
        return URLSession(configuration: configuration)
    }

    private static let bodies: [String: String] = [
        "/.well-known/oauth-protected-resource/api/v1": """
        {"resource":"https://mail.test.invalid/api/v1",
         "authorization_servers":["https://mail.test.invalid/api/auth"],
         "scopes_supported":["mail:read","mail:write","mail:send"],
         "bearer_methods_supported":["header"]}
        """,
        "/.well-known/oauth-authorization-server/api/auth": """
        {"issuer":"https://mail.test.invalid/api/auth",
         "authorization_endpoint":"https://mail.test.invalid/api/auth/oauth2/authorize",
         "token_endpoint":"https://mail.test.invalid/api/auth/oauth2/token",
         "registration_endpoint":"https://mail.test.invalid/api/auth/oauth2/register",
         "code_challenge_methods_supported":["S256"]}
        """,
        "/api/auth/oauth2/register": #"{"client_id":"cid_registered"}"#,
        "/api/auth/oauth2/token": """
        {"access_token":"hqb_access_1","token_type":"Bearer","refresh_token":"hqb_refresh_1",
         "expires_in":3600,"scope":"mail:read mail:write mail:send offline_access"}
        """,
    ]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Self.bodies[url.path]
        let response = HTTPURLResponse(
            url: url,
            statusCode: body == nil ? 404 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
