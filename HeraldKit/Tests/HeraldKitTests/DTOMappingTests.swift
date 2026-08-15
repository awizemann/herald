import Foundation
import Testing
@testable import HeraldKit

/// These tests fail if the generated client drops or renames a spec field, or if
/// `Mapping.swift` wires a value to the wrong property. They assert concrete
/// values — including nullable fields arriving as `nil` — rather than just
/// "decoding succeeded", because the historical failure mode here was the OpenAPI
/// generator silently omitting every `anyOf: [X, null]` property.
@Suite struct DTOMappingTests {
    private func makeClient(_ server: FakeServer) -> HQBaseAPIClient {
        HQBaseAPIClient(origin: FakeServer.origin, tokens: FakeTokenProvider(), session: server.makeSession())
    }

    @Test("Message detail keeps every field, and null timestamps map to nil")
    func messageDetailMapping() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/messages/msg_01", .json(200, Fixtures.messageDetailJSON))

        let detail = try await makeClient(server).message(id: "msg_01")

        #expect(detail.id == "msg_01")
        #expect(detail.summary.threadID == "thr_09")
        #expect(detail.summary.mailboxID == "mbx_support")
        #expect(detail.summary.direction == .inbound)
        #expect(detail.summary.folder == .inbox)
        #expect(detail.summary.fromAddress == "ada@example.net")
        #expect(detail.summary.to == ["support@example.com"])
        #expect(detail.summary.subject == "Invoice question")
        #expect(detail.summary.receivedAt == Fixtures.date("2026-08-14T09:30:00.000Z"))
        // Nullable-on-the-wire fields must survive as nil, not vanish.
        #expect(detail.summary.sentAt == nil)
        #expect(detail.summary.readAt == nil)
        #expect(detail.summary.starredAt == nil)
        #expect(detail.summary.isUnread)
        #expect(!detail.summary.isStarred)
        #expect(detail.summary.hasAttachments)
        #expect(detail.summary.createdAt == Fixtures.date("2026-08-14T09:30:01.000Z"))

        #expect(detail.cc == ["billing@example.com"])
        #expect(detail.bcc.isEmpty)
        #expect(detail.deliveredToAddress == "support@example.com")
        #expect(detail.textBody == "Hi there, about invoice 4471.")
        #expect(detail.htmlAvailable)
        #expect(detail.rfcMessageID == "<abc@example.net>")
        #expect(detail.inReplyTo == nil)
        #expect(detail.references == ["<root@example.net>"])

        #expect(detail.attachments.map(\.id) == ["att_1", "att_2"])
        let inline = try #require(detail.attachments.first)
        #expect(inline.contentID == "logo@cid")
        #expect(inline.isInline)
        #expect(inline.messageID == "msg_01")
        #expect(inline.sizeBytes == 1234)
        let plain = detail.attachments[1]
        #expect(plain.contentID == nil)
        #expect(!plain.isInline)
        #expect(detail.downloadableAttachments.map(\.id) == ["att_2"])
    }

    @Test("Conversation page keeps nextCursor, thread identity and per-thread counters")
    func conversationPageMapping() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/conversations", .json(200, Fixtures.conversationPageJSON))

        let page = try await makeClient(server).listConversations(folder: .inbox)

        // A dropped `nextCursor` would silently break pagination in SyncEngine.
        #expect(page.nextCursor == "eyJvIjoyfQ")
        #expect(page.totalCount == nil)
        #expect(page.hasMore)
        #expect(page.conversations.count == 2)

        let unread = page.conversations[0]
        // Conversations are keyed by thread, not by the latest message id.
        #expect(unread.id == "thr_09")
        #expect(unread.latest.id == "msg_01")
        #expect(unread.latest.mailboxID == nil)
        #expect(unread.messageCount == 3)
        #expect(unread.unreadCount == 2)
        #expect(unread.isUnread)
        #expect(!unread.isStarred)

        let read = page.conversations[1]
        #expect(read.id == "thr_11")
        #expect(read.isStarred)
        #expect(!read.isUnread)
        #expect(read.latest.direction == .outbound)
        #expect(read.latest.folder == .sent)
        #expect(read.latest.receivedAt == nil)
        #expect(read.latest.sentAt == Fixtures.date("2026-08-13T18:00:00.000Z"))
        #expect(read.latest.readAt == Fixtures.date("2026-08-13T18:05:00.000Z"))
        #expect(read.latest.starredAt == Fixtures.date("2026-08-13T18:06:00.000Z"))
        // displayDate must prefer sentAt for outbound mail with no receivedAt.
        #expect(read.latest.displayDate == Fixtures.date("2026-08-13T18:00:00.000Z"))
    }

    @Test("Mailbox accessLevel maps, including the null case")
    func mailboxMapping() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/mailboxes", .json(200, Fixtures.mailboxesJSON))

        let mailboxes = try await makeClient(server).listMailboxes()

        #expect(mailboxes.map(\.id) == ["mbx_support", "mbx_catchall"])
        #expect(mailboxes[0].accessLevel == .manager)
        #expect(mailboxes[0].isActive)
        #expect(mailboxes[0].addresses.map(\.address) == ["support@example.com"])
        #expect(mailboxes[0].addresses[0].mailDomainID == "dom_1")
        #expect(mailboxes[0].sendableAddresses.count == 1)
        #expect(mailboxes[1].accessLevel == nil)
        #expect(!mailboxes[1].isActive)
        #expect(mailboxes[1].createdAt == Fixtures.date("2026-01-02T03:04:05.000Z"))
    }

    @Test("Message HTML keeps the null quoted section and the remote-media flags")
    func messageHTMLMapping() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/messages/msg_01/html", .json(200, Fixtures.messageHTMLJSON))

        let html = try await makeClient(server).messageHTML(id: "msg_01")

        #expect(html.html == "<p>Hi</p>")
        #expect(html.quotedHTML == nil)
        #expect(html.hasRemoteImages)
        #expect(!html.remoteMediaTrusted)
        // Drives the "load remote images" affordance in the reading pane.
        #expect(html.needsRemoteMediaConsent)
    }

    @Test("Inline image bytes come back with a sniffed MIME type")
    func inlineImageMapping() async throws {
        let server = FakeServer()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01, 0x02, 0x03])
        server.route(
            "GET",
            "/api/v1/messages/msg_01/inline/att_1",
            FakeResponse(status: 200, headers: ["Content-Type": "image/png"], body: png)
        )

        let payload = try await makeClient(server).inlineImage(messageID: "msg_01", attachmentID: "att_1")

        #expect(payload.data == png)
        // Fails if the sniffer regresses to a bare octet-stream, which would stop
        // the reading pane from building a usable data: URL.
        #expect(payload.mimeType == "image/png")
    }
}
