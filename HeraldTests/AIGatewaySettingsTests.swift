import Foundation
import HeraldKit
import Synchronization
import Testing

@testable import Herald

/// A dictionary-backed ``SecretStore`` — never the real Keychain.
private nonisolated final class MemorySecrets: SecretStore, Sendable {
    private let storage = Mutex<[String: Data]>([:])
    func data(for key: String) throws -> Data? { storage.withLock { $0[key] } }
    func set(_ data: Data, for key: String) throws { storage.withLock { $0[key] = data } }
    func removeValue(for key: String) throws { storage.withLock { $0[key] = nil } }
}

/// Answers every request with the status carried in its own header, so
/// parallel tests never share state.
private nonisolated final class GatewayStubProtocol: URLProtocol, @unchecked Sendable {
    static let header = "X-AIG-Stub-Status"

    static func session(status: Int) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayStubProtocol.self]
        configuration.httpAdditionalHeaders = [header: String(status)]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status = request.value(forHTTPHeaderField: Self.header).flatMap(Int.init) ?? 500
        let body = status == 200 ? #"{"choices":[{"message":{"content":"OK"}}]}"# : #"{"error":"no"}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.scratchDefaults)
struct AIGatewaySettingsTests {
    @Test func settingsRoundTripThroughDefaults() {
        let defaults = ScratchDefaults.make()
        AIGatewaySettings.setAccountID("  acct123 ", in: defaults)
        AIGatewaySettings.setGatewayID("herald-gw", in: defaults)
        AIGatewaySettings.setModel("@cf/meta/llama-3.1-8b-instruct-fp8", in: defaults)

        #expect(AIGatewaySettings.accountID(in: defaults) == "acct123")
        let configuration = AIGatewaySettings.configuration(in: defaults)
        #expect(configuration == AIGatewayConfiguration(
            accountID: "acct123", gatewayID: "herald-gw", model: "workers-ai/@cf/meta/llama-3.1-8b-instruct-fp8"
        ))
    }

    @Test func defaultModelMatchesWF1AndPrefixIsAddedOnce() {
        let defaults = ScratchDefaults.make()
        #expect(AIGatewaySettings.model(in: defaults) == AIGatewaySettings.recommendedModel)
        #expect(AIGatewaySettings.providerModel(for: AIGatewaySettings.recommendedModel) == AIGatewayConfiguration.defaultModel)
        #expect(AIGatewaySettings.providerModel(for: "workers-ai/@cf/x/y") == "workers-ai/@cf/x/y")
    }

    @Test func invalidModelIsNeverStored() {
        let defaults = ScratchDefaults.make()
        AIGatewaySettings.setModel("@cf/mistralai/mistral-small-3.1-24b-instruct", in: defaults)
        for bad in ["", "@cf/", "gpt-4o", "@cf/has space"] {
            AIGatewaySettings.setModel(bad, in: defaults)
        }
        #expect(AIGatewaySettings.model(in: defaults) == "@cf/mistralai/mistral-small-3.1-24b-instruct")
    }

    @Test(arguments: [("", "gw"), ("acct", ""), ("acct/../x", "gw"), ("acct", "g w")])
    func incompleteOrUnsafeConfigurationIsNil(account: String, gateway: String) {
        let defaults = ScratchDefaults.make()
        defaults.set(account, forKey: AIGatewaySettings.accountIDKey)
        defaults.set(gateway, forKey: AIGatewaySettings.gatewayIDKey)
        #expect(AIGatewaySettings.configuration(in: defaults) == nil)
    }

    @Test func isConfiguredNeedsBothConfigurationAndToken() throws {
        let defaults = ScratchDefaults.make()
        let secrets = MemorySecrets()
        try AIGatewaySettings.saveToken("tok", in: secrets)
        #expect(!AIGatewaySettings.isConfigured(in: defaults, secrets: secrets))

        AIGatewaySettings.setAccountID("acct", in: defaults)
        AIGatewaySettings.setGatewayID("gw", in: defaults)
        #expect(AIGatewaySettings.isConfigured(in: defaults, secrets: secrets))

        try AIGatewaySettings.removeToken(in: secrets)
        #expect(!AIGatewaySettings.isConfigured(in: defaults, secrets: secrets))
    }

    @Test @MainActor func savedTokenGoesToKeychainOnlyAndIsNotEchoed() throws {
        let defaults = ScratchDefaults.make()
        let secrets = MemorySecrets()
        let model = AIGatewaySettingsModel(defaults: defaults, secrets: secrets)
        model.accountID = "acct"
        model.tokenDraft = "  s3cret-token-value \n"
        model.saveToken()

        #expect(try secrets.string(for: AIGatewayClient.tokenKey) == "s3cret-token-value")
        #expect(model.hasToken)
        #expect(model.tokenDraft.isEmpty)
        let everything = defaults.dictionaryRepresentation().values.map { "\($0)" }.joined()
        #expect(!everything.contains("s3cret-token-value"))

        model.removeToken()
        #expect(!model.hasToken)
        #expect(try secrets.string(for: AIGatewayClient.tokenKey) == nil)
    }

    /// Fails if saving a token stops resuming a paused classifier — before WF5
    /// only a changed account/gateway/model did, so a replaced token left
    /// classification paused until the next config edit.
    @Test @MainActor func savingATokenResumesClassificationOnlyOnSuccess() {
        nonisolated struct FailingSecrets: SecretStore {
            func data(for key: String) throws -> Data? { nil }
            func set(_ data: Data, for key: String) throws { throw CocoaError(.fileWriteNoPermission) }
            func removeValue(for key: String) throws {}
        }
        var resumed = 0
        let model = AIGatewaySettingsModel(
            defaults: ScratchDefaults.make(), secrets: MemorySecrets(), onTokenSaved: { resumed += 1 }
        )
        model.tokenDraft = "   "
        model.saveToken()
        #expect(resumed == 0)
        model.tokenDraft = "new-token"
        model.saveToken()
        #expect(resumed == 1)

        let failing = AIGatewaySettingsModel(
            defaults: ScratchDefaults.make(), secrets: FailingSecrets(), onTokenSaved: { resumed += 1 }
        )
        failing.tokenDraft = "new-token"
        failing.saveToken()
        #expect(resumed == 1)
        #expect(failing.tokenError != nil)
    }

    @Test @MainActor func customModelPersistsOnlyWhenValidAndReloads() {
        let defaults = ScratchDefaults.make()
        let model = AIGatewaySettingsModel(defaults: defaults, secrets: MemorySecrets())
        #expect(model.modelSelection == AIGatewaySettings.recommendedModel)

        model.modelSelection = AIGatewaySettingsModel.customSelection
        model.customModel = "@cf/goo"      // valid prefix mid-typing
        model.customModel = "@cf/google/gemma-3-12b-it"
        model.customModel = "@cf/google/gemma 3"   // invalid — ignored
        #expect(AIGatewaySettings.model(in: defaults) == "@cf/google/gemma-3-12b-it")

        let reloaded = AIGatewaySettingsModel(defaults: defaults, secrets: MemorySecrets())
        #expect(reloaded.modelSelection == AIGatewaySettingsModel.customSelection)
        #expect(reloaded.customModel == "@cf/google/gemma-3-12b-it")
    }

    @Test @MainActor func testConnectionReportsPlainEnglishResults() async throws {
        let defaults = ScratchDefaults.make()
        AIGatewaySettings.setAccountID("acct", in: defaults)
        AIGatewaySettings.setGatewayID("gw", in: defaults)
        let secrets = MemorySecrets()

        let noToken = AIGatewaySettingsModel(defaults: defaults, secrets: secrets, session: GatewayStubProtocol.session(status: 200))
        await noToken.testConnection()
        #expect(noToken.testResult == .failure(AIGatewaySettings.message(for: .missingToken)))

        try AIGatewaySettings.saveToken("tok", in: secrets)
        let ok = AIGatewaySettingsModel(defaults: defaults, secrets: secrets, session: GatewayStubProtocol.session(status: 200))
        await ok.testConnection()
        #expect(ok.testResult == .success)

        let rejected = AIGatewaySettingsModel(defaults: defaults, secrets: secrets, session: GatewayStubProtocol.session(status: 401))
        await rejected.testConnection()
        #expect(rejected.testResult == .failure(AIGatewaySettings.message(for: .unauthorized)))
    }

    @Test func routeIsInTheHeraldGroup() {
        let herald = SettingsRoute.rootGroups.first { $0.title == "Herald" }
        #expect(herald?.routes.contains(.aiGateway) == true)
        #expect(SettingsRoute.aiGateway.resolved(hasAccount: false, visibleDomainIDs: []) == .aiGateway)
        #expect(SettingsRoute.aiGateway.breadcrumb(accountLabel: "Studio", domainName: nil) == "Settings › Herald")
        #expect(SettingsRoute.aiGateway.title == "AI Gateway")
    }

    @Test func privacyPageDisclosesWhatClassificationSends() {
        let text = PrivacySettingsPane.classificationDisclosure
        for phrase in ["sender", "subject", "message text", "Cloudflare AI Gateway", "Nothing is sent", "logging", "does not train"] {
            #expect(text.contains(phrase))
        }
    }
}
