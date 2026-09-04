import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "oauth")

/// The handful of raw HTTP calls the OAuth layer makes.
///
/// The generated `HeraldAPI` client covers `/api/v1` only; discovery, registration
/// and the token endpoint live outside the spec, so they are plain `URLSession`
/// requests. Kept in one place so error mapping is uniform.
nonisolated enum OAuthHTTP {
    /// Cap on any auth response body. Discovery/token documents are a few hundred
    /// bytes; anything larger is a misconfigured server, not something to buffer.
    static let maxResponseBytes = 256 * 1024

    struct Response: Sendable {
        var status: Int
        var body: Data
    }

    static func send(_ request: URLRequest, using session: URLSession) async throws -> Response {
        do {
            // `session.bytes(for:)` streams the body, so the cap is enforced as
            // bytes arrive rather than after `session.data(for:)` has already
            // buffered an unbounded response in full. A malicious or
            // misconfigured server that answers with an enormous body is
            // stopped mid-download instead of after paying for the allocation.
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OAuthError.malformedTokenResponse
            }
            var data = Data()
            data.reserveCapacity(min(maxResponseBytes, 16 * 1024))
            for try await byte in stream {
                data.append(byte)
                guard data.count <= maxResponseBytes else {
                    logger.error("oauth response too large from \(request.url?.path ?? "", privacy: .public)")
                    throw OAuthError.malformedTokenResponse
                }
            }
            return Response(status: http.statusCode, body: data)
        } catch let error as OAuthError {
            throw error
        } catch {
            logger.warning("oauth request failed: \(error.localizedDescription, privacy: .private)")
            throw OAuthError.transport(MailAPIError.TransportFailure(error))
        }
    }

    static func get(_ url: URL, using session: URLSession) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request, using: session)
    }

    static func postJSON(_ url: URL, body: Data, using session: URLSession) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return try await send(request, using: session)
    }

    /// Token endpoint calls are `application/x-www-form-urlencoded` requests with
    /// JSON responses (RFC 6749 §4.1.3).
    static func postForm(_ url: URL, fields: [(String, String)], using session: URLSession) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formEncode(fields).utf8)
        return try await send(request, using: session)
    }

    /// `application/x-www-form-urlencoded`: percent-encode everything outside the
    /// unreserved set. `URLComponents` would leave `+` and `&` intact in values.
    static func formEncode(_ fields: [(String, String)]) -> String {
        fields
            .map { "\(escape($0.0))=\(escape($0.1))" }
            .joined(separator: "&")
    }

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: PKCE.unreserved) ?? value
    }

    /// Turns an OAuth error response into ``OAuthError/server(error:description:)``.
    /// Falls back to the status code when the body is not the documented shape.
    static func oauthError(from response: Response) -> OAuthError {
        struct Payload: Decodable {
            let error: String
            let errorDescription: String?
            enum CodingKeys: String, CodingKey {
                case error
                case errorDescription = "error_description"
            }
        }
        // The error body is best-effort context; an unparseable body just falls back to the HTTP-status error, so the caller still gets a `.server` error either way.
        guard let payload = try? JSONDecoder().decode(Payload.self, from: response.body) else {
            logger.error("token endpoint returned HTTP \(response.status) with an unreadable body")
            return .server(error: "http_\(response.status)", description: nil)
        }
        // `invalid_grant` stays `.server` here; only ``AccountTokenProvider`` knows
        // that an invalid grant on *refresh* means the account must sign in again.
        logger.warning("oauth error \(payload.error, privacy: .public)")
        return .server(error: payload.error, description: payload.errorDescription)
    }
}
