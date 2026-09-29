import Foundation
import Testing
@testable import HeraldKit

@Suite("AI Gateway client and classifier")
struct AIGatewayClientTests {
    static let path = "/v1/acct123/gw-test/compat/chat/completions"
    static let config = AIGatewayConfiguration(accountID: "acct123", gatewayID: "gw-test", model: "workers-ai/@cf/test/model")
    static let candidates = [
        ClassificationCandidate(id: "lbl_bug", name: "Bug", description: "defect in the app"),
        ClassificationCandidate(id: "lbl_support", name: "Support", description: "user asking for help"),
    ]

    private func makeClient(_ server: FakeServer, token: String? = "tok-secret") throws -> AIGatewayClient {
        let secrets = InMemorySecretStore()
        if let token { try secrets.setString(token, for: AIGatewayClient.tokenKey) }
        return AIGatewayClient(configuration: Self.config, secrets: secrets, session: server.makeSession(), userAgent: "Herald/9.9")
    }

    private static func reply(_ content: String) -> FakeResponse {
        let encoded = String(decoding: try! JSONEncoder().encode(content), as: UTF8.self)
        return .json(200, #"{"choices":[{"message":{"role":"assistant","content":\#(encoded)}}]}"#)
    }

    private func classify(reply content: String) async throws -> ClassificationCandidate? {
        let server = FakeServer()
        server.route("POST", Self.path, Self.reply(content))
        let input = ClassificationInput(from: "a@b.c", subject: "Crash", body: "It crashes")
        return try await EmailClassifier(client: makeClient(server)).classify(input, candidates: Self.candidates)
    }

    @Test func requestShape() async throws {
        let server = FakeServer()
        server.route("POST", Self.path, Self.reply("OK"))
        try await makeClient(server).testConnection()

        let request = try #require(server.requests(path: Self.path).first)
        #expect(request.method == "POST")
        #expect(request.headers["cf-aig-authorization"] == "Bearer tok-secret")
        #expect(request.headers["User-Agent"] == "Herald/9.9")
        #expect(request.authorization == nil)
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["model"] as? String == "workers-ai/@cf/test/model")
        #expect(body["temperature"] as? Double == 0)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
    }

    @Test func missingTokenSendsNothing() async throws {
        let server = FakeServer()
        await #expect(throws: AIGatewayError.missingToken) { try await makeClient(server, token: nil).testConnection() }
        #expect(server.requests.isEmpty)
    }

    @Test func invalidConfigurationRejected() {
        #expect(AIGatewayConfiguration(accountID: "a/b", gatewayID: "g").endpoint == nil)
        #expect(AIGatewayConfiguration(accountID: "", gatewayID: "g").endpoint == nil)
        #expect(Self.config.endpoint?.path == Self.path)
    }

    @Test(arguments: [
        (401, #"{"error":"x"}"#, AIGatewayError.unauthorized),
        (402, #"{"success":false,"error":[{"code":2021,"message":"no credits"}]}"#, .insufficientCredits),
        (403, #"{"success":false,"error":[{"internalCode":5018,"message":"not allowed"}]}"#, .modelNotAllowed),
        (403, "error code: 1010", .blocked),
        (403, #"{"error":"other"}"#, .http(status: 403)),
        (429, "", .rateLimited),
        (500, "", .http(status: 500)),
    ])
    func errorMapping(status: Int, body: String, expected: AIGatewayError) async throws {
        let server = FakeServer()
        server.route("POST", Self.path, FakeResponse(status: status, body: Data(body.utf8)))
        await #expect(throws: expected) { try await makeClient(server).testConnection() }
    }

    @Test func missingChoicesIsMalformed() async throws {
        let server = FakeServer()
        server.route("POST", Self.path, .json(200, #"{"choices":[]}"#))
        await #expect(throws: AIGatewayError.malformedResponse) { try await makeClient(server).testConnection() }
    }

    @Test func classifiesOnListAnswer() async throws {
        #expect(try await classify(reply: #"{"tag": "Bug", "confidence": 0.9}"#)?.id == "lbl_bug")
    }

    @Test func proseWrappedJSONAndCaseInsensitiveMatch() async throws {
        let reply = "<think>\n</think>\nSure! Here is the answer: {\"tag\": \"support\", \"confidence\": 0.2} Hope that helps."
        #expect(try await classify(reply: reply)?.id == "lbl_support")
    }

    @Test func matchesByIDToo() throws {
        #expect(try EmailClassifier.parse(#"{"tag":"lbl_bug"}"#, candidates: Self.candidates)?.name == "Bug")
    }

    @Test(arguments: [#"{"tag": "none"}"#, #"{"tag": "Marketing"}"#, #"{"tag": ""}"#, #"{"confidence": 1}"#])
    func noneOrOffListIsNil(reply: String) async throws {
        #expect(try await classify(reply: reply) == nil)
    }

    @Test func replyWithoutJSONThrows() async throws {
        await #expect(throws: AIGatewayError.malformedResponse) { try await classify(reply: "I think it is a Bug.") }
    }

    @Test func noCandidatesSkipsNetwork() async throws {
        let server = FakeServer()
        let result = try await EmailClassifier(client: makeClient(server))
            .classify(ClassificationInput(from: "", subject: "", body: ""), candidates: [])
        #expect(result == nil)
        #expect(server.requests.isEmpty)
    }

    @Test func promptListsTagsAndNone() {
        let prompt = EmailClassifier.systemPrompt(for: Self.candidates)
        #expect(prompt.contains("- Bug: defect in the app\n- Support: user asking for help"))
        #expect(prompt.contains("or none"))
        #expect(prompt.hasSuffix("/no_think"))
    }

    @Test func bodyIsTruncated() async throws {
        let server = FakeServer()
        server.route("POST", Self.path, Self.reply(#"{"tag":"none"}"#))
        let body = String(repeating: "a", count: EmailClassifier.maxBodyCharacters) + "TAIL"
        _ = try await EmailClassifier(client: makeClient(server))
            .classify(ClassificationInput(from: "x@y.z", subject: "Hi", body: body), candidates: Self.candidates)

        let request = try #require(server.requests(path: Self.path).first)
        let json = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let user = try #require((json["messages"] as? [[String: String]])?.last?["content"])
        #expect(user.hasPrefix("From: x@y.z\nSubject: Hi\n\n"))
        #expect(user.count(where: { $0 == "a" }) == EmailClassifier.maxBodyCharacters)
        #expect(!user.contains("TAIL"))
    }
}
