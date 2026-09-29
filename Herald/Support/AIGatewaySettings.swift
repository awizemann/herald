import Foundation
import HeraldKit

/// One entry in the AI Gateway model picker.
nonisolated struct AIGatewayModelOption: Hashable, Sendable, Identifiable {
    /// The bare Workers AI id, e.g. `@cf/qwen/qwen3-30b-a3b-fp8`.
    let id: String
    let name: String
    var isRecommended = false
}

/// Where the AI Gateway's non-secret settings live, and the one place that
/// turns them into an ``AIGatewayConfiguration``.
///
/// Account ID, gateway ID and model are in `UserDefaults` (none is a secret).
/// The gateway TOKEN is only ever in the Keychain under
/// ``AIGatewayClient/tokenKey`` — nothing here writes it anywhere else.
///
/// The model is stored as the bare `@cf/...` id the user sees; the
/// `workers-ai/` provider prefix the gateway's compat endpoint needs is added
/// by ``providerModel(for:)`` and nowhere else.
enum AIGatewaySettings {
    nonisolated static let accountIDKey = "aiGateway.accountID"
    nonisolated static let gatewayIDKey = "aiGateway.gatewayID"
    nonisolated static let modelKey = "aiGateway.model"

    nonisolated static let providerPrefix = "workers-ai/"
    nonisolated static let recommendedModel = "@cf/qwen/qwen3-30b-a3b-fp8"

    nonisolated static let curatedModels: [AIGatewayModelOption] = [
        AIGatewayModelOption(id: recommendedModel, name: "Qwen3 30B A3B", isRecommended: true),
        AIGatewayModelOption(id: "@cf/meta/llama-4-scout-17b-16e-instruct", name: "Llama 4 Scout 17B"),
        AIGatewayModelOption(id: "@cf/meta/llama-3.1-8b-instruct-fp8", name: "Llama 3.1 8B"),
        AIGatewayModelOption(id: "@cf/mistralai/mistral-small-3.1-24b-instruct", name: "Mistral Small 3.1 24B"),
    ]

    // MARK: Non-secret settings

    nonisolated static func accountID(in defaults: UserDefaults) -> String {
        defaults.string(forKey: accountIDKey) ?? ""
    }

    nonisolated static func setAccountID(_ value: String, in defaults: UserDefaults) {
        write(value, forKey: accountIDKey, in: defaults)
    }

    nonisolated static func gatewayID(in defaults: UserDefaults) -> String {
        defaults.string(forKey: gatewayIDKey) ?? ""
    }

    nonisolated static func setGatewayID(_ value: String, in defaults: UserDefaults) {
        write(value, forKey: gatewayIDKey, in: defaults)
    }

    /// The bare `@cf/...` model id; the recommended model when unset or invalid.
    nonisolated static func model(in defaults: UserDefaults) -> String {
        guard let stored = defaults.string(forKey: modelKey), isValidModelID(stored) else { return recommendedModel }
        return stored
    }

    /// Ignores an invalid id rather than storing it, so a half-typed custom id
    /// never becomes the model classification runs against.
    nonisolated static func setModel(_ value: String, in defaults: UserDefaults) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidModelID(trimmed) else { return }
        defaults.set(trimmed, forKey: modelKey)
    }

    /// `@cf/` followed by a non-empty path with no whitespace.
    nonisolated static func isValidModelID(_ value: String) -> Bool {
        value.hasPrefix("@cf/") && value.count > 4 && !value.contains(where: \.isWhitespace)
    }

    /// The ONE mapping from the stored model id to what the gateway expects.
    nonisolated static func providerModel(for bareModel: String) -> String {
        bareModel.hasPrefix(providerPrefix) ? bareModel : providerPrefix + bareModel
    }

    // MARK: Derived

    /// The configuration classification should use, or `nil` while the
    /// account or gateway ID is missing or would not form a valid endpoint.
    nonisolated static func configuration(in defaults: UserDefaults) -> AIGatewayConfiguration? {
        let configuration = AIGatewayConfiguration(
            accountID: accountID(in: defaults),
            gatewayID: gatewayID(in: defaults),
            model: providerModel(for: model(in: defaults))
        )
        return configuration.endpoint == nil ? nil : configuration
    }

    /// A complete configuration AND a saved token — the gate WF3/WF4 check
    /// before offering or running classification.
    nonisolated static func isConfigured(in defaults: UserDefaults, secrets: any SecretStore) -> Bool {
        configuration(in: defaults) != nil && hasToken(in: secrets)
    }

    // MARK: Token (Keychain only)

    nonisolated static func hasToken(in secrets: any SecretStore) -> Bool {
        guard let token = try? secrets.string(for: AIGatewayClient.tokenKey) else { return false }
        return !token.isEmpty
    }

    nonisolated static func saveToken(_ token: String, in secrets: any SecretStore) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try secrets.setString(trimmed, for: AIGatewayClient.tokenKey)
    }

    nonisolated static func removeToken(in secrets: any SecretStore) throws {
        try secrets.removeValue(for: AIGatewayClient.tokenKey)
    }

    // MARK: Test connection wording

    /// Plain-English result of a failed "Test connection".
    nonisolated static func message(for error: AIGatewayError) -> String {
        switch error {
        case .missingToken: "Save a gateway token first."
        case .invalidConfiguration: "Check the Account ID and Gateway ID — they should be letters, numbers, dashes or underscores."
        case .unauthorized: "The gateway rejected the token. Paste a fresh token from the gateway's Settings."
        case .insufficientCredits: "This model needs AI Gateway credits. Add credits in Cloudflare or pick another model."
        case .modelNotAllowed: "This model isn't enabled for your Cloudflare account. Pick another model."
        case .blocked: "Cloudflare blocked the request (error 1010). Check the gateway's security settings."
        case .rateLimited: "The gateway is rate limiting requests. Try again in a minute."
        case .http(let status): "The gateway answered with an unexpected error (HTTP \(status))."
        case .malformedResponse: "The gateway answered, but not in a form Herald understands. Try another model."
        case .transport: "Couldn't reach Cloudflare. Check your internet connection."
        }
    }

    private nonisolated static func write(_ value: String, forKey key: String, in defaults: UserDefaults) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
    }
}
