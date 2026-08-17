import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "oauth")

/// RFC 8414 authorization server metadata, narrowed to the fields Herald uses.
public nonisolated struct OAuthServerMetadata: Sendable, Codable, Hashable {
    public let issuer: String
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let registrationEndpoint: URL?
    /// RFC 8628; HQBase exposes a device flow (verification at `/device`) that
    /// Herald does not use yet but records so a headless mode can.
    public let deviceAuthorizationEndpoint: URL?
    /// RFC 7009. Absent on servers with no revocation support, in which case
    /// sign-out skips revocation silently.
    public let revocationEndpoint: URL?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case deviceAuthorizationEndpoint = "device_authorization_endpoint"
        case revocationEndpoint = "revocation_endpoint"
    }

    public init(
        issuer: String,
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        registrationEndpoint: URL? = nil,
        deviceAuthorizationEndpoint: URL? = nil,
        revocationEndpoint: URL? = nil
    ) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.deviceAuthorizationEndpoint = deviceAuthorizationEndpoint
        self.revocationEndpoint = revocationEndpoint
    }
}

/// RFC 9728 protected resource metadata for `/api/v1`.
public nonisolated struct ProtectedResourceMetadata: Sendable, Codable, Hashable {
    public let resource: String
    public let authorizationServers: [String]
    public let scopesSupported: [String]

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }

    public init(resource: String, authorizationServers: [String] = [], scopesSupported: [String] = []) {
        self.resource = resource
        self.authorizationServers = authorizationServers
        self.scopesSupported = scopesSupported
    }
}

/// Everything the flow needs about one origin, resolved once per sign-in.
public nonisolated struct OAuthConfiguration: Sendable, Hashable {
    public let origin: URL
    public let server: OAuthServerMetadata
    /// The audience every token must be bound to — `{origin}/api/v1`.
    public let resource: String
    public let scopes: [String]

    public init(origin: URL, server: OAuthServerMetadata, resource: String, scopes: [String]) {
        self.origin = origin
        self.server = server
        self.resource = resource
        self.scopes = scopes
    }
}

/// Resolves an origin's OAuth endpoints from its `.well-known` documents.
public nonisolated struct OAuthDiscovery: Sendable {
    /// The API permissions Herald asks for when the server does not advertise its scopes.
    public static let defaultScopes = ["mail:read", "mail:write", "mail:send", "offline_access"]
    /// Always requested in addition to whatever the resource advertises. `offline_access`
    /// is NOT an API permission, so HQBase's protected-resource metadata deliberately
    /// leaves it out of `scopes_supported` — and without it the server issues no
    /// refresh token, so the sign-in silently dies with the first access token (~1 h).
    /// Real-run finding 2026-08-17 (Herald issue #1 and the owner's own account).
    public static let alwaysRequestedScopes = ["offline_access"]
    static let protectedResourcePath = "/.well-known/oauth-protected-resource/api/v1"
    static let authorizationServerPath = "/.well-known/oauth-authorization-server"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Advertised API scopes (or the defaults) plus the scopes Herald must always ask
    /// for, deduplicated and order-preserving.
    public static func requestedScopes(advertised: [String]) -> [String] {
        var seen = Set<String>()
        let base = advertised.isEmpty ? defaultScopes : advertised
        return (base + alwaysRequestedScopes).filter { seen.insert($0).inserted }
    }

    public func configuration(for rawOrigin: URL) async throws -> OAuthConfiguration {
        let origin = Account.normalize(rawOrigin)
        let resource = try await protectedResource(for: origin)
        let server = try await serverMetadata(
            for: origin,
            issuer: resource.authorizationServers.first.flatMap(URL.init(string:))
        )
        let scopes = Self.requestedScopes(advertised: resource.scopesSupported)
        return OAuthConfiguration(origin: origin, server: server, resource: resource.resource, scopes: scopes)
    }

    // MARK: Protected resource

    /// A server that predates the metadata document still works: the resource is
    /// `{origin}/api/v1` by construction, so a miss here is a soft failure.
    func protectedResource(for origin: URL) async throws -> ProtectedResourceMetadata {
        let url = Self.url(origin, path: Self.protectedResourcePath)
        let fallback = ProtectedResourceMetadata(resource: Account.resource(for: origin))
        do {
            let response = try await OAuthHTTP.get(url, using: session)
            guard (200..<300).contains(response.status) else {
                logger.warning("protected-resource metadata returned HTTP \(response.status); assuming defaults")
                return fallback
            }
            return try decode(ProtectedResourceMetadata.self, from: response.body, url: url)
        } catch {
            logger.warning("protected-resource metadata unavailable; assuming defaults")
            return fallback
        }
    }

    // MARK: Authorization server

    /// HQBase's issuer is `{origin}/api/auth`, so RFC 8414 puts the metadata at the
    /// path-suffixed `{origin}/.well-known/oauth-authorization-server/api/auth`.
    /// The bare path is tried second for servers that only publish that.
    func serverMetadata(for origin: URL, issuer: URL?) async throws -> OAuthServerMetadata {
        var candidates: [URL] = []
        if let issuer, let suffixed = Self.metadataURL(forIssuer: issuer) { candidates.append(suffixed) }
        if let assumed = Self.metadataURL(forIssuer: Self.url(origin, path: "/api/auth")) {
            candidates.append(assumed)
        }
        candidates.append(Self.url(origin, path: Self.authorizationServerPath))

        var seen = Set<String>()
        var lastFailure: OAuthError?
        for url in candidates where seen.insert(url.absoluteString).inserted {
            do {
                let response = try await OAuthHTTP.get(url, using: session)
                guard (200..<300).contains(response.status) else {
                    lastFailure = .discoveryFailed(url: url.absoluteString, reason: .status)
                    continue
                }
                let metadata = try decode(OAuthServerMetadata.self, from: response.body, url: url)
                guard Self.endpointsAreTrusted(metadata, for: origin) else {
                    logger.error(
                        "metadata at \(url.absoluteString, privacy: .public) points off-origin; refusing it"
                    )
                    lastFailure = .discoveryFailed(url: url.absoluteString, reason: .untrustedEndpoints)
                    continue
                }
                return metadata
            } catch let error as OAuthError {
                lastFailure = error
            }
        }
        logger.error("no authorization server metadata at \(origin.absoluteString, privacy: .public)")
        throw lastFailure ?? .discoveryFailed(url: origin.absoluteString, reason: .status)
    }

    /// Every endpoint the flow will actually contact must be https on the origin's
    /// own host. A `.well-known` document is fetched before anything is trusted,
    /// so without this check a server (or anything that can answer for it) could
    /// send the authorization request — and therefore the user's credentials and
    /// the minted token — to a host of its choosing.
    static func endpointsAreTrusted(_ metadata: OAuthServerMetadata, for origin: URL) -> Bool {
        let host = origin.host?.lowercased()
        guard host != nil else { return false }
        func sameOrigin(_ url: URL?) -> Bool {
            guard let url else { return true } // Absent endpoints are simply unused.
            return url.scheme?.lowercased() == "https" && url.host?.lowercased() == host
        }
        guard let issuer = URL(string: metadata.issuer), sameOrigin(issuer) else { return false }
        return sameOrigin(metadata.authorizationEndpoint)
            && sameOrigin(metadata.tokenEndpoint)
            && sameOrigin(metadata.registrationEndpoint)
            && sameOrigin(metadata.revocationEndpoint)
    }

    /// Replaces an origin's path outright. `appendingPathComponent` would collapse
    /// or escape the leading slash of a `.well-known` path depending on the origin's
    /// trailing slash; this is unambiguous.
    static func url(_ origin: URL, path: String) -> URL {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { return origin }
        components.path = path
        return components.url ?? origin
    }

    /// RFC 8414 §3.1: insert `/.well-known/oauth-authorization-server` between the
    /// issuer's host and its path. `https://x/api/auth` →
    /// `https://x/.well-known/oauth-authorization-server/api/auth`.
    static func metadataURL(forIssuer issuer: URL) -> URL? {
        guard var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false) else { return nil }
        let issuerPath = components.path
        guard !issuerPath.isEmpty, issuerPath != "/" else { return nil }
        components.path = authorizationServerPath + (issuerPath.hasPrefix("/") ? issuerPath : "/" + issuerPath)
        return components.url
    }

    /// Decoding failures become ``OAuthError/discoveryFailed`` — a malformed
    /// `.well-known` document must not surface as a raw `DecodingError`.
    private func decode<T: Decodable>(_ type: T.Type, from data: Data, url: URL) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            logger.error("could not decode metadata at \(url.absoluteString, privacy: .public)")
            throw OAuthError.discoveryFailed(url: url.absoluteString, reason: .decoding)
        }
    }
}
