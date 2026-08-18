import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "oauth")

/// Refreshes an access token. Split out of ``OAuthSession`` so
/// ``AccountTokenProvider`` depends only on the operation it actually performs
/// (and so tests can gate a refresh without a URL protocol).
public nonisolated protocol TokenRefreshing: Sendable {
    func refresh(refreshToken: String) async throws -> OAuthTokens
}

/// Drives the OAuth 2.1 authorization-code + PKCE flow against one origin.
///
/// A `nonisolated struct`, not an actor: it owns no mutable state — the per-attempt
/// verifier/state travel in ``AuthorizationRequest``, and the only thing that needs
/// serializing (refresh) is serialized by the ``AccountTokenProvider`` actor. A value
/// type also means sync/compose can hold copies without hops.
public nonisolated struct OAuthSession: Sendable, TokenRefreshing {
    public let configuration: OAuthConfiguration
    public let clientID: String
    public let redirectURI: URL
    private let session: URLSession

    public init(
        configuration: OAuthConfiguration,
        clientID: String,
        redirectURI: URL = DynamicClientRegistration.redirectURI,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.session = session
    }

    /// One in-flight authorization attempt. Held by the caller between building the
    /// URL and validating the callback; never persisted.
    public nonisolated struct AuthorizationRequest: Sendable, Hashable {
        public let url: URL
        public let state: String
        public let pkce: PKCE
    }

    // MARK: - Authorize

    public func makeAuthorizationRequest(
        scopes: [String]? = nil,
        pkce: PKCE = PKCE(),
        state: String = OAuthSession.randomState()
    ) -> AuthorizationRequest {
        let scope = (scopes ?? configuration.scopes).joined(separator: " ")
        let query: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", clientID),
            ("redirect_uri", redirectURI.absoluteString),
            ("scope", scope),
            ("state", state),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", PKCE.method),
            // RFC 8707. Without it the minted token is not bound to /api/v1 and every
            // Mail API call answers 401 INVALID_OAUTH_TOKEN.
            ("resource", configuration.resource),
        ]

        var components = URLComponents(
            url: configuration.server.authorizationEndpoint,
            resolvingAgainstBaseURL: false
        )
        // Percent-encode ourselves: URLComponents leaves `+` in a query value alone,
        // which a form-decoding server reads back as a space.
        let existingQuery = components?.percentEncodedQuery
        components?.percentEncodedQuery = [existingQuery, OAuthHTTP.formEncode(query)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "&")

        let url = components?.url ?? configuration.server.authorizationEndpoint
        return AuthorizationRequest(url: url, state: state, pkce: pkce)
    }

    /// Extracts the authorization code from the callback, refusing anything whose
    /// `state` does not match. Returns before any network call so a forged callback
    /// never reaches the token endpoint.
    public func authorizationCode(from callback: URL, for request: AuthorizationRequest) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        guard value("state") == request.state else {
            logger.error("authorization callback state mismatch; response discarded")
            throw OAuthError.stateMismatch
        }
        if let error = value("error") {
            logger.warning("authorization denied: \(error, privacy: .public)")
            throw OAuthError.server(error: error, description: value("error_description"))
        }
        guard let code = value("code"), !code.isEmpty else {
            logger.error("authorization callback carried neither code nor error")
            throw OAuthError.missingAuthorizationCode
        }
        return code
    }

    // MARK: - Token endpoint

    public func exchange(code: String, pkce: PKCE) async throws -> OAuthTokens {
        try await requestTokens([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI.absoluteString),
            ("client_id", clientID),
            ("code_verifier", pkce.verifier),
            ("resource", configuration.resource),
        ])
    }

    public func refresh(refreshToken: String) async throws -> OAuthTokens {
        try await requestTokens([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
            ("resource", configuration.resource),
        ])
    }

    /// Public client: no `client_secret` is ever sent (the server registered us with
    /// `token_endpoint_auth_method: "none"`).
    private func requestTokens(_ fields: [(String, String)]) async throws -> OAuthTokens {
        let response = try await OAuthHTTP.postForm(
            configuration.server.tokenEndpoint,
            fields: fields,
            using: session
        )
        guard (200..<300).contains(response.status) else {
            throw OAuthHTTP.oauthError(from: response)
        }
        // A 2xx with a body we cannot decode is not a token; the decode failure is reduced to a single `.malformedTokenResponse`, so the specific parse error carries no useful information to the caller.
        guard let payload = try? JSONDecoder().decode(TokenResponse.self, from: response.body) else {
            logger.error("token response was 2xx but unreadable")
            throw OAuthError.malformedTokenResponse
        }
        return OAuthTokens(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: payload.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            scope: payload.scope ?? configuration.scopes.joined(separator: " ")
        )
    }

    struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
        }
    }

    /// 32 CSPRNG bytes, base64url — the same generator PKCE uses.
    public static func randomState() -> String { PKCE().verifier }
}
