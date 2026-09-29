import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "ai-gateway")

/// Where classification requests go: one Cloudflare AI Gateway and one Workers AI model.
/// Holds no secret — the gateway token lives in the Keychain under ``AIGatewayClient/tokenKey``.
public nonisolated struct AIGatewayConfiguration: Sendable, Hashable, Codable {
    public var accountID: String
    public var gatewayID: String
    /// Provider-prefixed model, e.g. `workers-ai/@cf/qwen/qwen3-30b-a3b-fp8`.
    public var model: String

    public static let defaultModel = "workers-ai/@cf/qwen/qwen3-30b-a3b-fp8"

    public init(accountID: String, gatewayID: String, model: String = AIGatewayConfiguration.defaultModel) {
        self.accountID = accountID
        self.gatewayID = gatewayID
        self.model = model
    }

    /// The OpenAI-compatible endpoint; `nil` when an ID would not form a single path segment.
    public var endpoint: URL? {
        let segment = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard [accountID, gatewayID].allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(segment.contains) })
        else { return nil }
        return URL(string: "https://gateway.ai.cloudflare.com/v1/\(accountID)/\(gatewayID)/compat/chat/completions")
    }
}

/// Everything that can go wrong talking to the gateway. Never carries the token.
public nonisolated enum AIGatewayError: Error, Sendable, Hashable {
    /// No gateway token in the Keychain.
    case missingToken
    /// Account or gateway ID is empty or not URL-safe.
    case invalidConfiguration
    /// 401 — the gateway token was rejected.
    case unauthorized
    /// 402 (Cloudflare code 2021) — the model needs AI Gateway credits.
    case insufficientCredits
    /// 403 code 5018 — the model is not enabled for this account.
    case modelNotAllowed
    /// 403 "error code: 1010" — Cloudflare's bot filter rejected the client.
    case blocked
    /// 429.
    case rateLimited
    /// Any other non-2xx status.
    case http(status: Int)
    /// A 2xx body without the expected `choices[0].message.content`, or content with no JSON answer.
    case malformedResponse
    case transport(MailAPIError.TransportFailure)
}

nonisolated extension AIGatewayError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingToken: "No AI Gateway token is saved."
        case .invalidConfiguration: "The AI Gateway account or gateway ID is invalid."
        case .unauthorized: "The AI Gateway rejected the token."
        case .insufficientCredits: "This model needs AI Gateway credits."
        case .modelNotAllowed: "This model is not enabled for the Cloudflare account."
        case .blocked: "Cloudflare blocked the request (error 1010)."
        case .rateLimited: "The AI Gateway is rate limiting requests."
        case .http(let status): "The AI Gateway returned HTTP \(status)."
        case .malformedResponse: "The model's answer could not be read."
        case .transport(let failure): failure.localizedDescription
        }
    }
}

/// Minimal client for the AI Gateway's OpenAI-compatible chat-completions endpoint.
public nonisolated struct AIGatewayClient: Sendable {
    /// Keychain key (in ``KeychainStore``'s namespace) holding the gateway token.
    public static let tokenKey = "ai-gateway-token"

    public let configuration: AIGatewayConfiguration
    private let secrets: any SecretStore
    private let session: URLSession
    private let userAgent: String

    /// `userAgent` must stay explicit: Cloudflare answers default/bot-like agents with 403 "error code: 1010".
    public init(
        configuration: AIGatewayConfiguration,
        secrets: any SecretStore,
        session: URLSession = .shared,
        userAgent: String = AIGatewayClient.defaultUserAgent
    ) {
        self.configuration = configuration
        self.secrets = secrets
        self.session = session
        self.userAgent = userAgent
    }

    public static var defaultUserAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Herald/\(version)"
    }

    /// Sends one system + user turn at temperature 0 and returns the assistant's text.
    public func complete(system: String, user: String, maxTokens: Int = 300) async throws -> String {
        guard let url = configuration.endpoint else { throw AIGatewayError.invalidConfiguration }
        guard let token = try secrets.string(for: Self.tokenKey), !token.isEmpty else {
            throw AIGatewayError.missingToken
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "cf-aig-authorization")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: configuration.model,
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
            temperature: 0,
            maxTokens: maxTokens
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.warning("ai gateway request failed: \(error.localizedDescription, privacy: .private)")
            throw AIGatewayError.transport(MailAPIError.TransportFailure(error))
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw AIGatewayError.malformedResponse }
        guard (200..<300).contains(status) else {
            let error = Self.error(status: status, body: data)
            logger.error("ai gateway HTTP \(status): \(String(describing: error), privacy: .public)")
            throw error
        }
        guard let reply = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = reply.choices.first?.message.content
        else { throw AIGatewayError.malformedResponse }
        return content
    }

    /// Cheap round trip that proves URL, token and model all work. Not a 5-token
    /// budget: a reasoning model (the default Qwen3) spends that thinking and
    /// returns `content: null`, which read as "not a form Herald understands".
    public func testConnection() async throws {
        _ = try await complete(system: "Reply with OK. /no_think", user: "ping", maxTokens: 64)
    }

    /// Maps a non-2xx response. Cloudflare's JSON error bodies carry a numeric `code`
    /// (or `internalCode`); the 1010 bot block is a plain-text body.
    static func error(status: Int, body: Data) -> AIGatewayError {
        let text = String(decoding: body.prefix(4096), as: UTF8.self)
        let codes = Set(text.matches(of: /"(?:internalCode|code)"\s*:\s*(\d+)/).compactMap { Int($0.1) })
        switch status {
        case 401: return .unauthorized
        case 402: return .insufficientCredits
        case 403 where text.contains("error code: 1010"): return .blocked
        case 403 where codes.contains(5018): return .modelNotAllowed
        case 429: return .rateLimited
        default: return codes.contains(2021) ? .insufficientCredits : .http(status: status)
        }
    }
}

private nonisolated struct ChatRequest: Encodable {
    struct Message: Encodable { let role: String; let content: String }
    let model: String
    let messages: [Message]
    let temperature: Double
    let maxTokens: Int
    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
    }
}

private nonisolated struct ChatResponse: Decodable {
    struct Choice: Decodable { let message: Message }
    struct Message: Decodable { let content: String? }
    let choices: [Choice]
}
