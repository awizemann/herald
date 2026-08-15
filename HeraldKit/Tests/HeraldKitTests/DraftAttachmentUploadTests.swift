import Foundation
import Testing
@testable import HeraldKit

@Suite struct DraftAttachmentUploadTests {
    /// Fails if the multipart body loses the part name, the filename, or the raw
    /// bytes — all three are required for the server to store the attachment, and
    /// none of them are visible in the typed API surface.
    @Test("Attachment upload posts a multipart body carrying the filename and bytes")
    func multipartBodyIsWellFormed() async throws {
        let server = FakeServer()
        server.route("POST", "/api/v1/drafts/dft_1/attachments", .json(201, Fixtures.draftAttachmentJSON))
        let client = HQBaseAPIClient(
            origin: FakeServer.origin,
            tokens: FakeTokenProvider(),
            session: server.makeSession()
        )
        let payload = Data("hello world".utf8)

        let attachment = try await client.addDraftAttachment(
            draftID: "dft_1",
            filename: "quote.txt",
            mimeType: "text/plain",
            data: payload
        )

        #expect(attachment.id == "datt_7")
        #expect(attachment.filename == "quote.txt")
        #expect(attachment.sizeBytes == 11)

        let request = try #require(server.requests(path: "/api/v1/drafts/dft_1/attachments").first)
        let contentType = try #require(request.headers["Content-Type"])
        #expect(contentType.hasPrefix("multipart/form-data"))
        #expect(contentType.contains("boundary="))

        let body = request.bodyText
        #expect(body.contains(#"name="file""#))
        #expect(body.contains(#"filename="quote.txt""#))
        #expect(body.contains("hello world"))
        // A body that only has headers means the payload never got attached.
        #expect(request.body.count > payload.count)
    }

    @Test("Draft round-trips through create and re-read with its version stamp")
    func draftContentRoundTrip() async throws {
        let draftJSON = """
        {
          "id": "dft_1",
          "version": 4,
          "updatedAt": "2026-08-14T10:00:00.000Z",
          "attachments": [\(Fixtures.draftAttachmentJSON)],
          "mailboxId": "mbx_support",
          "replyToMessageId": "msg_01",
          "forwardOfMessageId": null,
          "from": "support@example.com",
          "to": ["ada@example.net"],
          "cc": [],
          "bcc": [],
          "subject": "Re: Invoice question",
          "text": "On it.",
          "html": ""
        }
        """
        let server = FakeServer()
        server.route("POST", "/api/v1/drafts", .json(201, draftJSON))
        let client = HQBaseAPIClient(
            origin: FakeServer.origin,
            tokens: FakeTokenProvider(),
            session: server.makeSession()
        )

        let draft = try await client.createDraft(
            DraftInput(mailboxID: "mbx_support", replyToMessageID: "msg_01", from: "support@example.com", to: ["ada@example.net"])
        )

        #expect(draft.id == "dft_1")
        #expect(draft.version == 4)
        #expect(draft.updatedAt == Fixtures.date("2026-08-14T10:00:00.000Z"))
        #expect(draft.attachments.map(\.filename) == ["quote.txt"])
        #expect(draft.content.mailboxID == "mbx_support")
        #expect(draft.content.replyToMessageID == "msg_01")
        #expect(draft.content.forwardOfMessageID == nil)
        #expect(draft.content.subject == "Re: Invoice question")
        // editableContent must stamp the version or the next PATCH 409s.
        #expect(draft.editableContent.version == 4)

        let posted = try #require(server.requests(path: "/api/v1/drafts").first?.compactBodyText)
        #expect(posted.contains(#""mailboxId":"mbx_support""#))
        #expect(posted.contains(#""replyToMessageId":"msg_01""#))
    }

    /// End-to-end over the wire, because the conflict contract spans three layers
    /// that are each individually plausible: the version stamp has to reach the
    /// PATCH body, the middleware has to map a 409 envelope to
    /// `.server(code:"DRAFT_CONFLICT")` (not a bare `http_409`), and the outbox has
    /// to recognise that code and retry exactly once. A fake at any one boundary
    /// would keep passing while the real chain 409s forever.
    @Test("A 409 DRAFT_CONFLICT over the wire is retried once with the refetched version")
    func draftConflictRetriesOverTheWire() async throws {
        func draftJSON(version: Int, subject: String) -> String {
            """
            {"id":"dft_1","version":\(version),"updatedAt":"2026-08-14T10:00:00.000Z","attachments":[],
             "mailboxId":"mbx_support","replyToMessageId":null,"forwardOfMessageId":null,
             "from":"support@example.com","to":["ada@example.net"],"cc":[],"bcc":[],
             "subject":"\(subject)","text":"Hi there","html":""}
            """
        }
        let server = FakeServer()
        server.route("POST", "/api/v1/drafts", .json(201, draftJSON(version: 1, subject: "Hello")))
        // First PATCH conflicts; the retry (with the refetched stamp) succeeds.
        server.route(
            "PATCH",
            "/api/v1/drafts/dft_1",
            // One for the standalone mapping check below, one for the outbox's
            // first attempt; the outbox's single retry then succeeds.
            .error(409, code: "DRAFT_CONFLICT", message: "This draft changed in another session."),
            .error(409, code: "DRAFT_CONFLICT", message: "This draft changed in another session."),
            .json(200, draftJSON(version: 8, subject: "Edited"))
        )
        server.route("GET", "/api/v1/drafts/dft_1", .json(200, draftJSON(version: 7, subject: "Hello")))

        let client = HQBaseAPIClient(
            origin: FakeServer.origin,
            tokens: FakeTokenProvider(),
            session: server.makeSession()
        )

        // The raw mapping, asserted on its own so a failure names the right layer.
        await #expect(throws: MailAPIError.server(code: "DRAFT_CONFLICT", message: "This draft changed in another session.")) {
            _ = try await client.updateDraft(id: "dft_1", with: DraftInput(from: "support@example.com", version: 1))
        }

        let outbox = OutboxService(api: client)
        var draft = try await outbox.saveDraft(
            ComposeDraft(
                mode: .new(mailboxID: "mbx_support"),
                fromAddress: "support@example.com",
                to: ["ada@example.net"],
                subject: "Hello",
                body: "Hi there"
            )
        )
        #expect(draft.serverDraft?.version == 1)
        draft.subject = "Edited"
        draft = try await outbox.saveDraft(draft)
        #expect(draft.serverDraft?.version == 8, "The retry after the 409 did not land")

        let patches = server.requests(path: "/api/v1/drafts/dft_1").filter { $0.method == "PATCH" }
        #expect(patches.count == 3, "One standalone PATCH, then the outbox's conflict + retry")
        // Every PATCH must carry a version stamp; the retry must carry the refetched one.
        #expect(patches.allSatisfy { $0.compactBodyText.contains("\"version\":") })
        #expect(patches[1].compactBodyText.contains("\"version\":1"))
        #expect(patches[2].compactBodyText.contains("\"version\":7"), "The retry reused the stale stamp")
        #expect(server.requests(path: "/api/v1/drafts/dft_1").count { $0.method == "GET" } == 1)
    }
}
