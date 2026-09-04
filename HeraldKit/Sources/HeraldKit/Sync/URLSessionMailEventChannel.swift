import Foundation
import os
import OSLog

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "MailEvents")

/// Opens `GET /api/v1/events` with `URLSessionWebSocketTask`.
///
/// The upgrade is authenticated by an ordinary `Authorization: Bearer` header —
/// verified against the 1.3.4 server, which routes the request through the same
/// `requireMailApiPrincipal` every REST call uses. There is no token query
/// parameter (which is the right call: a URL-borne credential ends up in
/// proxy logs) and no subprotocol to negotiate.
public nonisolated struct URLSessionMailEventChannels: MailEventChannelOpening {
    private let origin: URL
    private let configuration: URLSessionConfiguration

    /// - Parameters:
    ///   - origin: the account's server origin, e.g. `https://mail.example.com`.
    ///     `https`/`wss` are rewritten to `wss`; `http`/`ws` are refused.
    ///   - configuration: injected in tests.
    public init(origin: URL, configuration: URLSessionConfiguration = .ephemeral) {
        self.origin = origin
        self.configuration = configuration
    }

    public func open(token: String) async throws -> any MailEventChannel {
        guard let url = Self.eventsURL(origin: origin) else {
            throw MailEventChannelError.transport("the account origin is not a usable URL")
        }
        // An empty token used to send no `Authorization` header at all, so the
        // server would fall back to a browser session. That fallback is a
        // silent downgrade for production callers — Herald always has a real
        // token, and a bug that hands this an empty one must fail loudly
        // rather than open an unauthenticated-looking socket. Anything that
        // deliberately wants the cookie-session path (the live test) uses its
        // own `MailEventChannelOpening` instead of going through here.
        guard !token.isEmpty else {
            throw MailEventChannelError.unauthorized
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let channel = WebSocketChannel(request: request, configuration: configuration)
        do {
            try await channel.open()
        } catch {
            // A `URLSession` keeps a STRONG reference to its delegate — which is
            // the channel — until it is invalidated, and only `close()` does
            // that. Dropping a channel whose handshake failed would leak a
            // session and a channel per attempt, on the one path that repeats
            // forever by design: a server that is down, or a grant that is dying.
            channel.close()
            throw error
        }
        return channel
    }

    /// The socket URL for an origin, with any path the origin carries preserved
    /// (a Herald account may live under a prefix).
    ///
    /// `http`/`ws` origins are refused (`nil`) rather than upgraded to a
    /// plaintext `ws://` socket: the bearer token in the `Authorization`
    /// header would otherwise go out over the wire in the clear. A real
    /// account origin is always `https`; anything else is a misconfiguration
    /// that must surface as a transport error, not a silent downgrade.
    static func eventsURL(origin: URL) -> URL? {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "https", "wss": components.scheme = "wss"
        default: return nil
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/api/v1/events"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

/// One `URLSessionWebSocketTask`, wrapped so failures arrive as
/// ``MailEventChannelError`` rather than as a bare `URLError`.
///
/// Each channel owns its own `URLSession` so the delegate maps one-to-one onto
/// one task — no task-to-continuation bookkeeping, and `invalidateAndCancel()`
/// on close is unambiguous. `nonisolated` and `@unchecked Sendable` with an
/// `OSAllocatedUnfairLock` (the sanctioned primitive for a type behind a
/// synchronous nonisolated protocol) because `URLSessionDelegate` callbacks
/// arrive on the session's own background queue.
/// `internal`, not `private`: `@testable import` needs it to build a
/// cookie-session request directly for the live-server test suite, which must
/// not go through ``URLSessionMailEventChannels/open(token:)`` (that path now
/// throws on an empty token by design — see ``MailEventChannelError``).
nonisolated final class WebSocketChannel: NSObject, MailEventChannel, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// Everything the delegate queue and the caller share.
    private struct State {
        var openContinuation: CheckedContinuation<Void, any Error>?
        var didOpen = false
        var didClose = false
        /// The reason the connection ended, recorded by the delegate. Read when a
        /// `receive()` fails, so the caller learns "401 at upgrade" rather than
        /// "socket not connected".
        var failure: MailEventChannelError?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!

    init(request: URLRequest, configuration: URLSessionConfiguration) {
        super.init()
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        self.task = session.webSocketTask(with: request)
    }

    /// Resumes the task and waits for the handshake to succeed or fail.
    ///
    /// Cancellation-aware: without this, tearing an account down while the
    /// handshake is in flight blocks `stop()` for the whole request timeout —
    /// the continuation is not interruptible and the channel is not yet stored
    /// anywhere the socket could close.
    func open() async throws {
        task.resume()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resolution: Result<Void, any Error>? = state.withLock { state in
                    if let failure = state.failure { return .failure(failure) }
                    if state.didOpen { return .success(()) }
                    state.openContinuation = continuation
                    return nil
                }
                switch resolution {
                case .some(.success): continuation.resume()
                case .some(.failure(let error)): continuation.resume(throwing: error)
                case .none: break
                }
            }
        } onCancel: {
            close()
        }
    }

    func receive() async throws -> String {
        do {
            switch try await task.receive() {
            case .string(let text): return text
            case .data(let data): return String(decoding: data, as: UTF8.self)
            @unknown default: return ""
            }
        } catch {
            throw endReason(fallback: error)
        }
    }

    func close() {
        let alreadyClosed = state.withLock { state in
            let was = state.didClose
            state.didClose = true
            return was
        }
        guard !alreadyClosed else { return }
        // Cancelling is what makes a PENDING `receive()` throw: `URLSessionWebSocketTask.receive()`
        // is a bridged completion-handler call and does NOT observe Task
        // cancellation, so nothing else can unblock a socket that has gone quiet.
        task.cancel(with: .goingAway, reason: nil)
        // Invalidating (rather than only cancelling) is what releases the
        // session's strong reference to this delegate; without it every
        // reconnect leaks a session and a channel.
        session.invalidateAndCancel()
    }

    /// Why the connection ended, preferring what the delegate recorded and
    /// falling back to the task's own close code / response.
    private func endReason(fallback: any Error) -> MailEventChannelError {
        if let recorded = state.withLock({ $0.failure }) { return recorded }
        if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
            return Self.rejection(status: response.statusCode)
        }
        let closeCode = task.closeCode
        if closeCode != .invalid {
            return .closed(code: closeCode.rawValue)
        }
        if (fallback as? URLError)?.code == .cancelled { return .closed(code: nil) }
        return .transport(Self.diagnostic(fallback))
    }

    static func rejection(status: Int) -> MailEventChannelError {
        status == 401 ? .unauthorized : .rejected(status: status)
    }

    /// A short, non-identifying description — never a URL or a response body.
    static func diagnostic(_ error: any Error) -> String {
        guard let urlError = error as? URLError else { return String(describing: type(of: error)) }
        return "URLError \(urlError.code.rawValue)"
    }

    private func finishOpen(with error: (any Error)?) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            if let error = error as? MailEventChannelError { state.failure = state.failure ?? error }
            if error == nil { state.didOpen = true }
            defer { state.openContinuation = nil }
            return state.openContinuation
        }
        guard let continuation else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        finishOpen(with: nil)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        // A close BEFORE the handshake completed still has to unblock `open()`.
        finishOpen(with: MailEventChannelError.closed(code: closeCode.rawValue))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let reason: MailEventChannelError
        if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
            // A rejected upgrade is an ordinary HTTP response: the server answers
            // 401 with a `WWW-Authenticate: Bearer …` challenge, 403 on scope,
            // 426 without the upgrade header, 503 when the event service is down.
            reason = Self.rejection(status: response.statusCode)
        } else if let error {
            reason = .transport(Self.diagnostic(error))
        } else {
            reason = .closed(code: nil)
        }
        finishOpen(with: reason)
    }
}
