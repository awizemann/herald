import Foundation
import HTTPTypes
import OpenAPIRuntime
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "api")

/// Injects the bearer token, transparently refreshes it once on `invalid_token`,
/// and converts every non-2xx response into a ``MailAPIError``.
///
/// Doing the error translation here (rather than per-operation) keeps mapping in
/// one place: the generated client only ever sees success responses, so
/// ``HQBaseAPIClient`` has a single `.ok`/`.created`/`.noContent` branch per call.
nonisolated struct AuthenticatingMiddleware: ClientMiddleware {
    /// Request bodies are buffered so a refreshed retry can replay them.
    static let maxReplayableRequestBytes = 32 * 1024 * 1024
    static let maxErrorBodyBytes = 64 * 1024

    private let tokens: any BearerTokenProvider

    init(tokens: any BearerTokenProvider) {
        self.tokens = tokens
    }

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        // Buffer once so the retry below can resend an identical body.
        let replayBytes: [UInt8]? = if let body {
            try await [UInt8](collecting: body, upTo: Self.maxReplayableRequestBytes)
        } else {
            nil
        }

        @Sendable func attempt(token: String) async throws -> (HTTPResponse, HTTPBody?) {
            var request = request
            request.headerFields[.authorization] = "Bearer \(token)"
            return try await next(request, replayBytes.map { HTTPBody($0) }, baseURL)
        }

        let used = try await tokens.accessToken()
        var (response, responseBody) = try await attempt(token: used)

        if response.status.code == 401, Self.isRefreshable(response) {
            logger.warning("401 invalid_token on \(operationID, privacy: .public); refreshing once")
            // The provider needs to know WHICH token was rejected: a 401 for a
            // token another request already replaced must not refresh again.
            let refreshed = try await tokens.refreshAccessToken(failedToken: used)
            (response, responseBody) = try await attempt(token: refreshed)
        }

        guard response.status.code < 400 else {
            throw await Self.error(from: response, body: responseBody, operationID: operationID)
        }
        return (response, responseBody)
    }

    // MARK: - Response classification

    /// Refresh only when the challenge says the token itself is bad. A 401 with no
    /// challenge is treated the same way (some proxies drop the header).
    static func isRefreshable(_ response: HTTPResponse) -> Bool {
        guard let challenge = response.headerFields[.wwwAuthenticate] else { return true }
        return authParameter("error", in: challenge) != "insufficient_scope"
    }

    static func error(from response: HTTPResponse, body: HTTPBody?, operationID: String) async -> MailAPIError {
        let challenge = response.headerFields[.wwwAuthenticate]
        let payload = await errorPayload(body)

        switch response.status.code {
        case 401:
            logger.warning("unauthorized on \(operationID, privacy: .public)")
            return .unauthorized
        case 403 where challenge.map({ authParameter("error", in: $0) == "insufficient_scope" }) == true:
            let scope = challenge.flatMap { authParameter("scope", in: $0) } ?? payload?.message ?? ""
            logger.warning("insufficient scope \(scope, privacy: .public) on \(operationID, privacy: .public)")
            return .insufficientScope(scope)
        case 404:
            logger.warning("not found on \(operationID, privacy: .public)")
            return .notFound
        case 410 where payload?.code == "CHANGE_CURSOR_EXPIRED":
            logger.warning("change cursor expired on \(operationID, privacy: .public); re-bootstrap required")
            return .cursorExpired
        default:
            let code = payload?.code ?? "http_\(response.status.code)"
            let message = payload?.message ?? response.status.reasonPhrase
            logger.error("\(operationID, privacy: .public) failed: \(code, privacy: .public)")
            return .server(code: code, message: message)
        }
    }

    /// Decodes the API's `{"error":{"code","message"}}` envelope.
    private static func errorPayload(_ body: HTTPBody?) async -> (code: String, message: String)? {
        guard let body else { return nil }
        do {
            let bytes = try await [UInt8](collecting: body, upTo: maxErrorBodyBytes)
            let envelope = try JSONDecoder().decode(ErrorEnvelope.self, from: Data(bytes))
            return (envelope.error.code, envelope.error.message)
        } catch {
            logger.warning("could not decode error envelope: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    private struct ErrorEnvelope: Decodable {
        struct Payload: Decodable {
            let code: String
            let message: String
        }
        let error: Payload
    }

    /// Pulls `name="value"` out of an RFC 6750 `WWW-Authenticate` challenge.
    static func authParameter(_ name: String, in challenge: String) -> String? {
        guard let range = challenge.range(of: "\(name)=\"") else { return nil }
        let rest = challenge[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}
