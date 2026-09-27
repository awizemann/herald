#if DEBUG
import Foundation
import HeraldKit
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "uitest")

/// What the scripted sign-in window does on its NEXT `authorize` call.
nonisolated enum SignInPresenterMode: Sendable, Equatable, Hashable {
    /// Answers at once with a valid callback (a code the fake server issued,
    /// and the request's own `state`).
    case succeed
    /// Never answers until the awaiting task is cancelled (Herald's Cancel) or
    /// ``ScriptedSignInPresenter/completePending()`` releases it — the wedged
    /// authentication agent, or a user still on the consent page.
    case hangUntilCancelled
    /// Throws `OAuthError.webAuthenticationFailed(reason)`.
    case fail(String)
    /// Throws `OAuthError.userCancelled` — the user closed the sign-in window.
    case userCancel

    static let defaultFailureReason = "UI test: the sign-in window reported an error."

    /// `succeed`, `hangUntilCancelled`, `userCancel`, `fail` or `fail:<reason>`.
    init?(argument: String) {
        switch argument {
        case "succeed": self = .succeed
        case "hangUntilCancelled": self = .hangUntilCancelled
        case "userCancel": self = .userCancel
        case "fail": self = .fail(Self.defaultFailureReason)
        default:
            guard argument.hasPrefix("fail:") else { return nil }
            let reason = String(argument.dropFirst("fail:".count))
            self = .fail(reason.isEmpty ? Self.defaultFailureReason : reason)
        }
    }

    /// Stable name for the status label (the reason is not included).
    var name: String {
        switch self {
        case .succeed: "succeed"
        case .hangUntilCancelled: "hangUntilCancelled"
        case .fail: "fail"
        case .userCancel: "userCancel"
        }
    }
}

/// Replaces `ASWebAuthenticationSession` in test mode. Shows nothing; answers
/// according to ``SignInPresenterMode``.
///
/// Honours Task cancellation exactly like `WebAuthenticationRunner`: a
/// cancelled wait throws `OAuthError.userCancelled`, whether the cancel lands
/// before or after the wait began. `os_unfair_lock` rather than an actor
/// because `AuthorizationPresenter` is a `nonisolated` protocol whose calls come
/// from the auth coordinator's tasks, and the cancel handler is synchronous.
nonisolated final class ScriptedSignInPresenter: AuthorizationPresenter, @unchecked Sendable {
    /// Mints the callback for a successful consent: in the harness, the fake
    /// server for the authorize URL's host issues a code (or refuses an
    /// unknown client, as HQBase does with its own error page).
    typealias CallbackIssuer = @Sendable (_ authorizeURL: URL) throws -> URL

    private struct Pending {
        let continuation: CheckedContinuation<URL, any Error>
        let url: URL
    }

    private struct State {
        var mode: SignInPresenterMode
        var attempts = 0
        var pending: [UUID: Pending] = [:]
        var cancelledEarly: Set<UUID> = []
        /// Ids whose wait has begun. A cancel for an id NOT in here ran before
        /// the wait parked; one for an id already released is ignored.
        var started: Set<UUID> = []
    }

    private let state: OSAllocatedUnfairLock<State>
    private let issueCallback: CallbackIssuer
    /// Told after every change a test can observe (attempts, pending count).
    private let didChange: @Sendable () -> Void

    init(
        mode: SignInPresenterMode = .succeed,
        issueCallback: @escaping CallbackIssuer,
        didChange: @escaping @Sendable () -> Void = {}
    ) {
        self.state = OSAllocatedUnfairLock(initialState: State(mode: mode))
        self.issueCallback = issueCallback
        self.didChange = didChange
    }

    var mode: SignInPresenterMode {
        get { state.withLock { $0.mode } }
        set {
            state.withLock { $0.mode = newValue }
            didChange()
        }
    }

    /// How many times Herald opened the (fake) sign-in window.
    var attemptCount: Int { state.withLock { $0.attempts } }

    /// Attempts currently parked in ``SignInPresenterMode/hangUntilCancelled``.
    var pendingCount: Int { state.withLock { $0.pending.count } }

    func resetCounters() {
        state.withLock { $0.attempts = 0 }
        didChange()
    }

    func authorize(url: URL, callbackScheme: String) async throws -> URL {
        let mode = state.withLock { state -> SignInPresenterMode in
            state.attempts += 1
            return state.mode
        }
        didChange()
        logger.info("scripted sign-in: \(mode.name, privacy: .public)")
        switch mode {
        case .succeed:
            return try issueCallback(url)
        case .fail(let reason):
            throw OAuthError.webAuthenticationFailed(reason)
        case .userCancel:
            throw OAuthError.userCancelled
        case .hangUntilCancelled:
            return try await hang(url: url)
        }
    }

    /// Answers every parked attempt as if consent completed.
    func completePending() {
        let released = state.withLock { state -> [Pending] in
            defer { state.pending.removeAll() }
            return Array(state.pending.values)
        }
        for pending in released {
            do {
                pending.continuation.resume(returning: try issueCallback(pending.url))
            } catch {
                pending.continuation.resume(throwing: error)
            }
        }
        didChange()
    }

    private func hang(url: URL) async throws -> URL {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                let parked = state.withLock { state -> Bool in
                    state.started.insert(id)
                    // The cancel ran before this closure: answer now, never park.
                    if state.cancelledEarly.remove(id) != nil { return false }
                    state.pending[id] = Pending(continuation: continuation, url: url)
                    return true
                }
                if parked {
                    didChange()
                } else {
                    continuation.resume(throwing: OAuthError.userCancelled)
                }
            }
        } onCancel: {
            let pending = state.withLock { state -> Pending? in
                guard let pending = state.pending.removeValue(forKey: id) else {
                    // Only a wait that has not begun needs the marker; one
                    // already answered (completePending) needs nothing.
                    if !state.started.contains(id) { state.cancelledEarly.insert(id) }
                    return nil
                }
                return pending
            }
            pending?.continuation.resume(throwing: OAuthError.userCancelled)
            didChange()
        }
    }
}
#endif
