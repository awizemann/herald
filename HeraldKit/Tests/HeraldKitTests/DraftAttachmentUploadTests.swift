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
}
