import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "oauth")

/// RFC 7591 dynamic client registration.
///
/// HQBase allows unauthenticated registration of public clients, which is how a
/// shipped app gets a `client_id` for a server it has never seen. The id is
/// persisted per origin in the Keychain and reused forever after.
public nonisolated struct DynamicClientRegistration: Sendable {
    /// Herald's custom-scheme redirect. Must match the app's `CFBundleURLTypes`.
    public static let redirectURI = URL(string: "herald://oauth/callback")!
    public static let callbackScheme = "herald"
    public static let clientName = "Herald"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Registers a public client and returns its `client_id`.
    ///
    /// - Parameter resource: `{origin}/api/v1`. The server restricts registrations to
    ///   its configured `clientRegistrationAllowedResources`, so the audience has to
    ///   be declared up front or the minted tokens cannot target the Mail API.
    public func register(
        at endpoint: URL,
        resource: String,
        scopes: [String] = OAuthDiscovery.defaultScopes
    ) async throws -> String {
        let body = ClientMetadata(
            clientName: Self.clientName,
            redirectURIs: [Self.redirectURI.absoluteString],
            grantTypes: ["authorization_code", "refresh_token"],
            responseTypes: ["code"],
            tokenEndpointAuthMethod: "none",
            scope: scopes.joined(separator: " "),
            resources: [resource]
        )

        let response = try await OAuthHTTP.postJSON(endpoint, body: try JSONEncoder().encode(body), using: session)
        // Registration answers 201 Created; accept any 2xx rather than pinning 200.
        guard (200..<300).contains(response.status) else {
            if let oauth = try? JSONDecoder().decode(RegistrationErrorPayload.self, from: response.body) {
                logger.error("client registration rejected: \(oauth.error, privacy: .public)")
                throw OAuthError.server(error: oauth.error, description: oauth.errorDescription)
            }
            logger.error("client registration failed with HTTP \(response.status)")
            throw OAuthError.registrationFailed(status: response.status)
        }
        guard let registered = try? JSONDecoder().decode(RegistrationResponse.self, from: response.body) else {
            logger.error("client registration response had no client_id")
            throw OAuthError.registrationFailed(status: response.status)
        }
        return registered.clientID
    }

    struct ClientMetadata: Encodable {
        let clientName: String
        let redirectURIs: [String]
        let grantTypes: [String]
        let responseTypes: [String]
        let tokenEndpointAuthMethod: String
        let scope: String
        let resources: [String]

        enum CodingKeys: String, CodingKey {
            case clientName = "client_name"
            case redirectURIs = "redirect_uris"
            case grantTypes = "grant_types"
            case responseTypes = "response_types"
            case tokenEndpointAuthMethod = "token_endpoint_auth_method"
            case scope
            case resources
        }
    }

    struct RegistrationResponse: Decodable {
        let clientID: String
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case scope
        }
    }

    struct RegistrationErrorPayload: Decodable {
        let error: String
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }
}
