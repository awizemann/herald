import Foundation

/// A label the model may pick, with the human-written description that steers it.
public nonisolated struct ClassificationCandidate: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let description: String

    public init(id: String, name: String, description: String) {
        self.id = id
        self.name = name
        self.description = description
    }
}

/// The parts of a message the model sees.
public nonisolated struct ClassificationInput: Sendable, Hashable {
    public var from: String
    public var subject: String
    public var body: String

    public init(from: String, subject: String, body: String) {
        self.from = from
        self.subject = subject
        self.body = body
    }
}

/// Picks at most one label for a message. Returns `nil` for "none" or any answer that
/// is not one of the candidates — the model's self-reported confidence is ignored (useless).
public nonisolated struct EmailClassifier: Sendable {
    /// Body characters sent to the model.
    public static let maxBodyCharacters = 4000

    private let client: AIGatewayClient

    public init(client: AIGatewayClient) {
        self.client = client
    }

    public func classify(_ input: ClassificationInput, candidates: [ClassificationCandidate]) async throws -> ClassificationCandidate? {
        guard !candidates.isEmpty else { return nil }
        let reply = try await client.complete(system: Self.systemPrompt(for: candidates), user: Self.userMessage(for: input))
        return try Self.parse(reply, candidates: candidates)
    }

    static func systemPrompt(for candidates: [ClassificationCandidate]) -> String {
        let tags = candidates.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        let names = candidates.map(\.name).joined(separator: ", ")
        return """
        You classify incoming emails into exactly one tag.
        Tags:
        \(tags)

        If no tag clearly fits, answer none. Reply with ONLY a JSON object: \
        {"tag": "<one of \(names), or none>", "confidence": <0..1>} /no_think
        """
    }

    static func userMessage(for input: ClassificationInput) -> String {
        "From: \(input.from)\nSubject: \(input.subject)\n\n\(input.body.prefix(maxBodyCharacters))"
    }

    /// Extracts the first `{`…last `}` (models sometimes wrap JSON in prose or think tags)
    /// and matches `tag` case-insensitively against candidate names, then ids.
    static func parse(_ reply: String, candidates: [ClassificationCandidate]) throws -> ClassificationCandidate? {
        struct Answer: Decodable { let tag: String? }
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close,
              let answer = try? JSONDecoder().decode(Answer.self, from: Data(reply[open...close].utf8))
        else { throw AIGatewayError.malformedResponse }
        guard let tag = answer.tag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else { return nil }
        func same(_ a: String) -> Bool { a.compare(tag, options: .caseInsensitive) == .orderedSame }
        return candidates.first { same($0.name) } ?? candidates.first { same($0.id) }
    }
}
