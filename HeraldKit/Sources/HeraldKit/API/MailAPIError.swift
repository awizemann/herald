import Foundation

/// The single error type every ``MailAPIClient`` method throws.
///
/// Generated `HeraldAPI` types never appear here — callers (auth, sync, UI) match
/// on these cases only.
public nonisolated enum MailAPIError: Error, Sendable, Hashable {
    /// 401: the access token is missing, expired or rejected (after one refresh attempt).
    case unauthorized
    /// 403 with `WWW-Authenticate: … error="insufficient_scope"`; payload is the required scope.
    case insufficientScope(String)
    /// 404 — including the "this server does not have that route" case, which is
    /// how a pre-`/changes` HQBase answers the journal endpoint.
    case notFound
    /// 410 `CHANGE_CURSOR_EXPIRED`: the journal no longer covers the stored
    /// change cursor, so the client must re-bootstrap.
    case cursorExpired
    /// Any other non-2xx, carrying the server's `{error:{code,message}}` body.
    case server(code: String, message: String)
    /// The request never produced an HTTP response (offline, TLS, cancelled).
    case transport(TransportFailure)
    /// A 2xx body did not match the schema.
    case decoding

    /// Hashable, Sendable stand-in for the underlying transport error.
    public nonisolated struct TransportFailure: Sendable, Hashable, CustomStringConvertible {
        public let domain: String
        public let code: Int
        public let localizedDescription: String

        public init(_ error: any Error) {
            let nsError = error as NSError
            self.domain = nsError.domain
            self.code = nsError.code
            self.localizedDescription = nsError.localizedDescription
        }

        public var description: String { "\(domain)(\(code)): \(localizedDescription)" }
    }
}

nonisolated extension MailAPIError {
    /// A payload-free classifier for logs.
    ///
    /// `String(describing:)` on this enum interpolates the server's `message` —
    /// which upstream echoes recipient addresses and subjects into — straight into
    /// the log. `errorDescription` has the same problem. Log this instead.
    public var logCode: String {
        switch self {
        case .unauthorized: "unauthorized"
        case .insufficientScope: "insufficient_scope"
        case .notFound: "not_found"
        case .cursorExpired: "cursor_expired"
        case .server(let code, _): "server(\(code))"
        case .transport(let failure): "transport(\(failure.domain)/\(failure.code))"
        case .decoding: "decoding"
        }
    }
}

nonisolated extension MailAPIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Your session has expired. Sign in again."
        case .insufficientScope(let scope):
            "This account is not authorized for \(scope)."
        case .notFound:
            "The requested item no longer exists."
        case .cursorExpired:
            "Herald's sync position expired; it will resynchronise from scratch."
        case .server(_, let message):
            message
        case .transport(let failure):
            failure.localizedDescription
        case .decoding:
            "The server sent a response Herald could not read."
        }
    }
}
