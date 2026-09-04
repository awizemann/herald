import Foundation
import Testing
@testable import HeraldKit

/// The label routes on the wire.
///
/// Verified live against a 1.3.4 instance (seeded `owner@hqbase.test`), which is
/// where these fixtures come from: the colour set is closed, the assignment
/// result carries the FULL set after the write, and the conversation route
/// answers with a `threadId` and an `affected` count spanning the thread.
@Suite("Label API")
struct LabelAPITests {
    private static func makeClient(_ server: FakeServer) -> HQBaseAPIClient {
        HQBaseAPIClient(
            origin: FakeServer.origin,
            tokens: FakeTokenProvider(),
            session: server.makeSession()
        )
    }

    private static let labelsJSON = """
    [
      {"id":"lbl_billing","name":"Billing","color":"green",
       "createdAt":"2026-05-07T18:08:15.379Z","updatedAt":"2026-09-04T18:08:15.379Z"},
      {"id":"lbl_customer","name":"Customer","color":"blue",
       "createdAt":"2026-05-07T18:08:15.379Z","updatedAt":"2026-09-04T18:08:15.379Z"}
    ]
    """

    @Test("Labels decode with their colour and their order")
    func labelsDecode() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/labels", .json(200, Self.labelsJSON))
        let labels = try await Self.makeClient(server).listLabels()
        #expect(labels.map(\.id) == ["lbl_billing", "lbl_customer"])
        #expect(labels.map(\.color) == [.green, .blue])
    }

    /// Fails if the client asks for membership with the repeated `labelIds` form:
    /// upstream ANDs those together (one `EXISTS` per id in `queries.ts`), which
    /// is a different question from "messages carrying this one label".
    @Test("Membership is asked for with the singular labelId filter")
    func membershipUsesSingularFilter() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/messages", .json(200, "[]"))
        _ = try await Self.makeClient(server).listMessages(labelID: "lbl_billing", limit: 100, cursor: nil)
        let query = try #require(server.requests(path: "/api/v1/messages").first?.query)
        #expect(query.contains("labelId=lbl_billing"))
        #expect(!query.contains("labelIds="))
    }

    /// Fails if add and remove are collapsed onto one verb: the route is the
    /// same and the METHOD is the whole difference between them.
    @Test("Assigning uses PUT and removing uses DELETE, on the same route")
    func assignmentVerbs() async throws {
        let server = FakeServer()
        let assigned = """
        {"affected":1,"assigned":true,"labelId":"lbl_billing","messageId":"msg_1",
         "labels":[{"id":"lbl_billing","name":"Billing","color":"green",
         "createdAt":"2026-05-07T18:08:15.379Z","updatedAt":"2026-09-04T18:08:15.379Z"}]}
        """
        let removed = """
        {"affected":1,"assigned":false,"labelId":"lbl_billing","messageId":"msg_1","labels":[]}
        """
        server.route("PUT", "/api/v1/messages/msg_1/labels/lbl_billing", .json(200, assigned))
        server.route("DELETE", "/api/v1/messages/msg_1/labels/lbl_billing", .json(200, removed))
        let client = Self.makeClient(server)

        let added = try await client.setLabel("lbl_billing", onMessage: "msg_1", assigned: true)
        #expect(added.assigned)
        #expect(added.labels.map(\.id) == ["lbl_billing"])

        let dropped = try await client.setLabel("lbl_billing", onMessage: "msg_1", assigned: false)
        #expect(!dropped.assigned)
        #expect(dropped.labels.isEmpty, "the answer is the full set AFTER the write, not what was removed")
    }

    /// The conversation route reports the thread and how many messages it
    /// touched; `messageId` is absent there, which is why it is optional on the
    /// DTO rather than defaulted to the id that was sent.
    @Test("A conversation assignment reports the thread and the union of its labels")
    func conversationAssignment() async throws {
        let server = FakeServer()
        server.route(
            "PUT",
            "/api/v1/conversations/msg_1/labels/lbl_billing",
            .json(200, """
            {"affected":2,"assigned":true,"labelId":"lbl_billing","threadId":"thr_1",
             "labels":[{"id":"lbl_billing","name":"Billing","color":"green",
             "createdAt":"2026-05-07T18:08:15.379Z","updatedAt":"2026-09-04T18:08:15.379Z"},
             {"id":"lbl_customer","name":"Customer","color":"blue",
             "createdAt":"2026-05-07T18:08:15.379Z","updatedAt":"2026-09-04T18:08:15.379Z"}]}
            """)
        )
        let result = try await Self.makeClient(server)
            .setLabel("lbl_billing", onConversation: "msg_1", assigned: true)
        #expect(result.threadID == "thr_1")
        #expect(result.messageID == nil)
        #expect(result.affected == 2)
        #expect(result.labels.map(\.id) == ["lbl_billing", "lbl_customer"])
    }

    /// Pins BOTH halves of the colour contract, including the unhappy one.
    ///
    /// The fallback is for the CACHE (`CachedLabel.colorRaw` is a plain string an
    /// older build may have written). On the WIRE the vendored spec declares the
    /// enum closed, so an eleventh server colour fails the whole list decode —
    /// asserted here so the day upstream adds one, this test names the reason
    /// instead of the feature going quiet.
    @Test("An unknown colour falls back in the cache but still fails the wire decode")
    func unknownColourHandling() async throws {
        #expect(LabelColor(serverValue: "chartreuse") == .gray)
        #expect(LabelColor(serverValue: "amber") == .amber)

        let server = FakeServer()
        server.route("GET", "/api/v1/labels", .json(200, """
        [{"id":"lbl_new","name":"New","color":"chartreuse",
          "createdAt":"2026-05-07T18:08:15.379Z","updatedAt":"2026-09-04T18:08:15.379Z"}]
        """))
        await #expect(throws: MailAPIError.self) {
            _ = try await Self.makeClient(server).listLabels()
        }
    }
}
