import AppKit
import AuthenticationServices
import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "oauth")

/// Shows the authorization URL to the user and hands back the redirect it lands on.
///
/// `nonisolated` so ``AuthCoordinator`` can pass it into value types and tests can
/// substitute a fake with no UI at all.
public nonisolated protocol AuthorizationPresenter: Sendable {
    func authorize(url: URL, callbackScheme: String) async throws -> URL
}

/// `ASWebAuthenticationSession`-backed presenter.
///
/// A `nonisolated struct` whose one method hops to ``WebAuthenticationRunner`` on the
/// main actor: `ASWebAuthenticationSession` and `NSWindow` are main-actor-only and
/// not `Sendable`, so they are created, started and released without ever crossing
/// an isolation boundary.
public nonisolated struct WebAuthenticationPresenter: AuthorizationPresenter {
    /// Left `false` on purpose. An ephemeral session would force a fresh login for
    /// every account add and, worse, would not see the HQBase browser session the
    /// user already has — the consent screen at `/oauth/consent` is a normal
    /// cookie-authenticated page. The cost is that signing out of Herald does not
    /// clear the shared web session; ``AuthCoordinator/signOut(_:)`` therefore only
    /// promises to drop Herald's tokens.
    public let prefersEphemeralWebBrowserSession: Bool

    public init(prefersEphemeralWebBrowserSession: Bool = false) {
        self.prefersEphemeralWebBrowserSession = prefersEphemeralWebBrowserSession
    }

    public func authorize(url: URL, callbackScheme: String) async throws -> URL {
        try await WebAuthenticationRunner.authorize(
            url: url,
            callbackScheme: callbackScheme,
            prefersEphemeralWebBrowserSession: prefersEphemeralWebBrowserSession
        )
    }
}

/// What ``WebAuthenticationRunner`` drives: the two things it does to a browser
/// session. Abstracted so the runner's own logic — the watchdog especially — is
/// testable without an `ASWebAuthenticationSession` and a real window server.
@MainActor
protocol WebAuthenticationDriving: AnyObject {
    /// `false` when the session refused to start at all.
    func start() -> Bool
    func cancel()
}

/// The callback AuthenticationServices hands back. Called on an XPC thread.
typealias WebAuthenticationCallback = @Sendable (URL?, (any Error)?) -> Void

/// Builds the driver for one authorization. Injected in tests.
typealias WebAuthenticationDriverFactory =
    @MainActor (_ url: URL, _ callbackScheme: String, _ prefersEphemeral: Bool, _ completion: @escaping WebAuthenticationCallback) -> any WebAuthenticationDriving

/// The real driver. Owns the session AND its anchor provider: the system does not
/// retain either (`presentationContextProvider` is weak), so both live exactly as
/// long as the driver does.
@MainActor
final class ASWebAuthenticationDriver: WebAuthenticationDriving {
    private let anchorProvider = KeyWindowAnchorProvider()
    private let session: ASWebAuthenticationSession

    init(
        url: URL,
        callbackScheme: String,
        prefersEphemeral: Bool,
        completion: @escaping WebAuthenticationCallback
    ) {
        session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme, completionHandler: completion)
        session.presentationContextProvider = anchorProvider
        session.prefersEphemeralWebBrowserSession = prefersEphemeral
    }

    func start() -> Bool { session.start() }
    func cancel() { session.cancel() }
}

/// Main-actor home for the non-Sendable AuthenticationServices objects.
enum WebAuthenticationRunner {
    /// When to start SAYING nothing has happened. Advisory only — it logs, it
    /// never touches the session.
    ///
    /// `start()` returning `true` only means the request reached the per-user
    /// authentication agent; that agent is out of process, and when it is wedged
    /// it neither presents a window nor ever calls back — which is exactly the
    /// hang reported in issue #9, unchanged across app relaunches.
    static let presentationWarning: Duration = .seconds(45)

    /// When to give up on the session entirely.
    ///
    /// Deliberately far beyond any human consent path. AuthenticationServices
    /// gives us NO "the window appeared" signal, so this timer necessarily covers
    /// the user reading the page, typing a password and fetching a second factor
    /// as well as the wedged-agent case — and killing a consent screen someone is
    /// typing into would be a worse bug than the one being fixed. Ten minutes
    /// still turns "forever, with no way out" into an error the UI can show;
    /// Cancel is the fast path, and it is now always available.
    static let presentationDeadline: Duration = .seconds(600)

    static let presentationTimeoutMessage = """
        Sign-in never completed: the browser window did not report back. \
        If no sign-in window ever appeared, macOS did not open it — quit Herald, \
        log out and back in (or restart), then try again.
        """

    /// Sessions are kept alive here for their lifetime: `ASWebAuthenticationSession`
    /// is not retained by the system, and `presentationContextProvider` is weak.
    private static var live: [UUID: LiveSession] = [:]

    private final class LiveSession {
        var driver: (any WebAuthenticationDriving)?
        /// Cleared by ``finish(_:with:)``, which is also what makes double
        /// resumption impossible when the callback and a cancellation race.
        var continuation: CheckedContinuation<URL, any Error>?
        /// The presentation deadline. Cancelled by ``finish(_:with:)``, so a
        /// normal completion — however slow — never leaves a timer behind and can
        /// never be overtaken by one.
        var watchdog: Task<Void, Never>?
    }

    static func authorize(
        url: URL,
        callbackScheme: String,
        prefersEphemeralWebBrowserSession: Bool,
        warning: Duration = presentationWarning,
        deadline: Duration = presentationDeadline,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        makeDriver: @escaping WebAuthenticationDriverFactory = {
            ASWebAuthenticationDriver(url: $0, callbackScheme: $1, prefersEphemeral: $2, completion: $3)
        }
    ) async throws -> URL {
        let token = UUID()
        live[token] = LiveSession()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                guard let holder = live[token] else {
                    // Cancelled before the sheet even existed.
                    continuation.resume(throwing: OAuthError.userCancelled)
                    return
                }
                holder.continuation = continuation

                let driver = makeDriver(url, callbackScheme, prefersEphemeralWebBrowserSession) { @Sendable callbackURL, error in
                    // AuthenticationServices calls this on its XPC thread. Under default
                    // MainActor isolation an un-annotated closure literal is inferred
                    // @MainActor and the runtime TRAPS on the isolation check
                    // (dispatch_assert_queue) — `@Sendable` makes it nonisolated; we then
                    // hop to main explicitly.
                    Task { @MainActor in
                        if let callbackURL {
                            finish(token, with: .success(callbackURL))
                        } else if let error {
                            finish(token, with: .failure(mapped(error)))
                        } else {
                            finish(token, with: .failure(OAuthError.missingAuthorizationCode))
                        }
                    }
                }
                holder.driver = driver

                guard driver.start() else {
                    logger.error("ASWebAuthenticationSession refused to start")
                    finish(
                        token,
                        with: .failure(
                            OAuthError.webAuthenticationFailed("Herald could not open the sign-in window.")
                        )
                    )
                    return
                }
                // Armed only once the session claims to be up: before that,
                // `start() == false` is already an answer. And only if the
                // session is still live — a driver that answers synchronously
                // inside `start()` has already finished, and a timer armed onto
                // a dead session is a task nothing will ever cancel.
                guard live[token] != nil else { return }
                holder.watchdog = Task { @MainActor in
                    // A cancelled sleep is the normal end of this task — the
                    // session finished and `finish` tore the watchdog down.
                    guard (try? await sleep(warning)) != nil, !Task.isCancelled, live[token] != nil else { return }
                    // Advisory: nothing is wrong with a user who reads the
                    // consent page slowly, but a wedged agent looks identical
                    // from here and this is the line that names it in the log.
                    logger.warning("web authentication has reported nothing yet; still waiting")

                    guard (try? await sleep(deadline - warning)) != nil, !Task.isCancelled else { return }
                    guard live[token] != nil else { return }
                    logger.error("web authentication never completed within the deadline")
                    live[token]?.driver?.cancel()
                    finish(token, with: .failure(OAuthError.webAuthenticationFailed(presentationTimeoutMessage)))
                }
            }
        } onCancel: {
            // The sheet has to be torn down on main, and the awaiting task has to
            // be resumed — without this, cancelling sign-in leaks both the window
            // and the continuation.
            Task { @MainActor in
                live[token]?.driver?.cancel()
                finish(token, with: .failure(OAuthError.userCancelled))
            }
        }
    }

    /// The single resumption point. Resuming a `CheckedContinuation` twice traps,
    /// so the callback, the start failure, the watchdog and cancellation all
    /// funnel through here.
    private static func finish(_ token: UUID, with result: Result<URL, any Error>) {
        guard let holder = live[token], let continuation = holder.continuation else { return }
        holder.continuation = nil
        live[token] = nil
        holder.watchdog?.cancel()
        holder.watchdog = nil
        continuation.resume(with: result)
    }

    private static func mapped(_ error: any Error) -> OAuthError {
        if (error as NSError).domain == ASWebAuthenticationSessionErrorDomain,
           (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
            logger.warning("sign-in cancelled by the user")
            return .userCancelled
        }
        logger.error("web authentication failed: \(error.localizedDescription, privacy: .private)")
        return .webAuthenticationFailed(error.localizedDescription)
    }
}

/// Anchors the sheet on the key window, falling back to any window (and finally a
/// detached one) so a menu-bar-only launch still presents.
final class KeyWindowAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApplication.shared.keyWindow
                ?? NSApplication.shared.mainWindow
                ?? NSApplication.shared.windows.first
                ?? ASPresentationAnchor()
        }
    }
}
