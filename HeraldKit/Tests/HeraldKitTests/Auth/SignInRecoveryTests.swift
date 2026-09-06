import Foundation
import Testing
@testable import HeraldKit

/// Herald #9: a sign-in that starts a browser session which never presents, and
/// auth requests that inherit `URLSession.shared`'s week-long resource timeout,
/// leave the user with a spinner and no way out. These cover the two bounds that
/// make that survivable.
@Suite struct SignInRecoveryTests {
    // MARK: - Presentation watchdog

    /// A driver that reports a successful start and then behaves like a wedged
    /// authentication agent: no window, no callback, ever.
    @MainActor
    final class SilentDriver: WebAuthenticationDriving {
        let startResult: Bool
        private(set) var cancelCount = 0
        /// Held so a test can complete the session late, on purpose.
        let completion: WebAuthenticationCallback

        init(startResult: Bool = true, completion: @escaping WebAuthenticationCallback) {
            self.startResult = startResult
            self.completion = completion
        }

        func start() -> Bool { startResult }
        func cancel() { cancelCount += 1 }
    }

    /// Fails if `start() == true` with no callback is still an unbounded wait —
    /// the exact shape of the reported hang. The deadline is injected, so this
    /// asserts the policy, not the clock.
    @MainActor
    @Test("a session that starts but never presents fails on the deadline")
    func watchdogFailsASessionThatNeverPresents() async throws {
        nonisolated(unsafe) var driver: SilentDriver?

        await #expect(throws: OAuthError.webAuthenticationFailed(
            WebAuthenticationRunner.presentationTimeoutMessage
        )) {
            try await WebAuthenticationRunner.authorize(
                url: URL(string: "https://mail.test.invalid/authorize")!,
                callbackScheme: "com.wizemann.herald",
                prefersEphemeralWebBrowserSession: false,
                deadline: .milliseconds(1),
                sleep: { _ in },
                makeDriver: { _, _, _, completion in
                    let made = SilentDriver(completion: completion)
                    driver = made
                    return made
                }
            )
        }

        // The window (if one ever does appear) is torn down, not orphaned.
        #expect(driver?.cancelCount == 1)
    }

    /// Fails if the watchdog is armed as a fire-and-forget timer: a slow but
    /// SUCCESSFUL authorization — a user who takes their time on the consent
    /// screen — must not be killed, and the timer must not outlive the session.
    @MainActor
    @Test("a slow but successful authorization survives, and tears the watchdog down")
    func watchdogIsTornDownOnSuccess() async throws {
        let expired = Expectation()
        let cancelled = Expectation()

        let callback = URL(string: "com.wizemann.herald:/oauth/callback?code=ok&state=s")!
        let result = try await WebAuthenticationRunner.authorize(
            url: URL(string: "https://mail.test.invalid/authorize")!,
            callbackScheme: "com.wizemann.herald",
            prefersEphemeralWebBrowserSession: false,
            deadline: .seconds(60),
            sleep: { duration in
                do {
                    try await Task.sleep(for: duration)
                    expired.fulfill()
                } catch {
                    cancelled.fulfill()
                    throw error
                }
            },
            makeDriver: { _, _, _, completion in
                // Answers after the watchdog has been armed, off the main actor,
                // exactly as AuthenticationServices does.
                let driver = SilentDriver(completion: completion)
                Task.detached {
                    try? await Task.sleep(for: .milliseconds(20))
                    completion(callback, nil)
                }
                return driver
            }
        )

        #expect(result == callback)
        await cancelled.wait()
        #expect(expired.isFulfilled == false, "the watchdog outlived the session it was guarding")
    }

    /// AuthenticationServices gives no "the window appeared" signal, so the
    /// deadline necessarily covers a human reading the consent page, typing a
    /// password and fetching a second factor. Fails if the advisory point is
    /// treated as the deadline — that would tear down a browser window someone is
    /// actively typing into, which is worse than the hang being fixed.
    @MainActor
    @Test("passing the advisory point does not kill a session that is still going")
    func advisoryDoesNotKillTheSession() async throws {
        let callback = URL(string: "com.wizemann.herald:/oauth/callback?code=ok&state=s")!

        let result = try await WebAuthenticationRunner.authorize(
            url: URL(string: "https://mail.test.invalid/authorize")!,
            callbackScheme: "com.wizemann.herald",
            prefersEphemeralWebBrowserSession: false,
            // The advisory passes almost immediately; the real deadline does not.
            warning: .milliseconds(1),
            deadline: .seconds(60),
            makeDriver: { _, _, _, completion in
                let driver = SilentDriver(completion: completion)
                Task.detached {
                    // Well past the advisory — the slow human.
                    try? await Task.sleep(for: .milliseconds(30))
                    completion(callback, nil)
                }
                return driver
            }
        )

        #expect(result == callback)
    }

    /// A one-shot flag that can be awaited without sleeping on a guess.
    nonisolated final class Expectation: @unchecked Sendable {
        private let lock = NSLock()
        private var fulfilled = false

        nonisolated var isFulfilled: Bool { lock.withLock { fulfilled } }
        nonisolated func fulfill() { lock.withLock { fulfilled = true } }

        /// Polls with early exit (no timing-dependent sleep-then-assert).
        nonisolated func wait(within: Duration = .seconds(2)) async {
            let deadline = ContinuousClock.now.advanced(by: within)
            while !isFulfilled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            #expect(isFulfilled, "condition never became true")
        }
    }

    // MARK: - Auth request timeouts

    /// Accepts the connection and then says nothing at all — a server that is up
    /// but wedged, which `URLSession.shared` would wait a WEEK for.
    nonisolated final class SilentServerProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {}
        override func stopLoading() {}
    }

    /// Fails if the auth session inherits `URLSession.shared`'s defaults: this
    /// would then hang until the resource timeout — 7 days — instead of surfacing
    /// something the UI can show.
    @Test("a server that accepts and never answers fails as a transport error, fast")
    func stalledServerSurfacesATransportError() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SilentServerProtocol.self]
        configuration.timeoutIntervalForRequest = 0.5
        configuration.timeoutIntervalForResource = 1
        let coordinator = AuthCoordinator(
            store: RecordingAccountStore(),
            presenter: FakeAuthorizationPresenter.succeeding(),
            session: URLSession(configuration: configuration)
        )

        let started = ContinuousClock.now
        await #expect(throws: OAuthError.self) {
            _ = try await coordinator.addAccount(origin: AuthFixtures.origin)
        }
        #expect(started.duration(to: .now) < .seconds(10), "the request was not bounded by a timeout")
    }

    /// Fails if the shared auth session is ever pointed back at `URLSession.shared`
    /// (or built with the framework defaults), which is what left the reported
    /// sign-in with no deadline at all.
    @Test("the auth session carries real timeouts")
    func authSessionHasTimeouts() {
        let configuration = AuthCoordinator.defaultSession.configuration
        #expect(configuration.timeoutIntervalForRequest == 15)
        #expect(configuration.timeoutIntervalForResource == 30)
        #expect(configuration.timeoutIntervalForResource < URLSessionConfiguration.default.timeoutIntervalForResource)
    }
}
