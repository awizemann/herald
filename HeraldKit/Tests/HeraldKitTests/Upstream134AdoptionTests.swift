import Foundation
import Testing
@testable import HeraldKit

/// The routes and enum members Herald picked up from upstream 1.3.4.
///
/// Everything here is asserted ON THE WIRE (URLProtocol fake server) rather than
/// against a fake client: the whole class of bug this phase fixes is "the DTO was
/// right and the request was not" — a forward that lost its forwarded message, an
/// action the client could name but never sent.
@Suite struct Upstream134AdoptionTests {
    private static func makeClient(_ server: FakeServer) -> HQBaseAPIClient {
        HQBaseAPIClient(
            origin: FakeServer.origin,
            tokens: FakeTokenProvider(),
            session: server.makeSession()
        )
    }

    private static let sentSummaryJSON = """
    {
      "id": "msg_fwd",
      "threadId": "thr_09",
      "mailboxId": "mbx_support",
      "direction": "outbound",
      "folder": "sent",
      "fromAddress": "support@example.com",
      "to": ["ada@example.net"],
      "subject": "Fwd: Invoice question",
      "snippet": "See below.",
      "receivedAt": null,
      "sentAt": "2026-09-04T10:00:00.000Z",
      "readAt": null,
      "starredAt": null,
      "hasAttachments": false,
      "createdAt": "2026-09-04T10:00:00.000Z"
    }
    """

    private static func summaryJSON(id: String, folder: String) -> String {
        """
        {"id":"\(id)","threadId":"thr_09","mailboxId":"mbx_support","direction":"inbound",
         "folder":"\(folder)","fromAddress":"ada@example.net","to":["support@example.com"],
         "subject":"Invoice question","snippet":"…","receivedAt":"2026-08-14T09:30:00.000Z",
         "sentAt":null,"readAt":null,"starredAt":null,"hasAttachments":false,
         "createdAt":"2026-08-14T09:30:01.000Z"}
        """
    }

    // MARK: - restore / unarchive

    /// Fails if either new member is dropped on the way to the path — before
    /// 1.3.4 the enums stopped at `trash`, and a missing member is a silent
    /// "unsupported_action" rather than a compile error at the call site.
    @Test("restore and unarchive reach the message route as path components", arguments: [
        (MessageAction.restore, "restore", "inbox"),
        (MessageAction.unarchive, "unarchive", "inbox")
    ])
    func messageRestoreActionsHitTheRoute(
        action: MessageAction,
        path: String,
        resultFolder: String
    ) async throws {
        let server = FakeServer()
        server.route(
            "POST",
            "/api/v1/messages/msg_01/\(path)",
            .json(200, Self.summaryJSON(id: "msg_01", folder: resultFolder))
        )

        let summary = try await Self.makeClient(server).perform(action, onMessage: "msg_01")

        #expect(summary.folder == .inbox)
        #expect(server.requests(path: "/api/v1/messages/msg_01/\(path)").count == 1)
    }

    /// The conversation route no-ops server-side unless the body's `folder`
    /// matches the one being undone (worker/.../conversation-queries.ts pushes
    /// `1 = 0` otherwise), so a dropped or wrong folder is a silent no-op.
    @Test("Conversation restore carries the trash folder the server matches on")
    func conversationRestoreSendsFolder() async throws {
        let server = FakeServer()
        server.route(
            "POST",
            "/api/v1/conversations/msg_01/restore",
            .json(200, #"{"affected":2,"threadId":"thr_09"}"#)
        )

        let result = try await Self.makeClient(server)
            .perform(.restore, onConversation: "msg_01", in: .trash)

        #expect(result.affected == 2)
        let body = try #require(
            server.requests(path: "/api/v1/conversations/msg_01/restore").first?.compactBodyText
        )
        #expect(body.contains(#""folder":"trash""#))
    }

    @Test("Conversation unarchive carries the archived folder")
    func conversationUnarchiveSendsFolder() async throws {
        let server = FakeServer()
        server.route(
            "POST",
            "/api/v1/conversations/msg_01/unarchive",
            .json(200, #"{"affected":1,"threadId":"thr_09"}"#)
        )

        _ = try await Self.makeClient(server)
            .perform(.unarchive, onConversation: "msg_01", in: .archived)

        let body = try #require(
            server.requests(path: "/api/v1/conversations/msg_01/unarchive").first?.compactBodyText
        )
        #expect(body.contains(#""folder":"archived""#))
    }

    /// The two enums must stay member-for-member identical: `MailStore` derives a
    /// `MessageAction` from a `ConversationAction`'s raw value to mutate the cache
    /// (MailStore.swift), and a member missing on one side silently skips the
    /// optimistic write for that verb.
    @Test("Message and conversation action enums carry the same members")
    func actionEnumsAgree() {
        #expect(
            MessageAction.allCases.map(\.rawValue) == ConversationAction.allCases.map(\.rawValue)
        )
        #expect(MessageAction.allCases.contains(.restore))
        #expect(MessageAction.allCases.contains(.unarchive))
    }

    // MARK: - POST /forward

    /// The bug this closes: a forward went out through `POST /send`, whose body
    /// has NO field naming the forwarded message — only a persisted draft carried
    /// it, so forwarding before the first autosave sent the user's text alone.
    /// Fails if the request lands on `/send`, or on `/forward` without the id.
    @Test("Forwarding posts to /forward with the forwarded message id")
    func forwardUsesTheDedicatedRoute() async throws {
        let server = FakeServer()
        server.route("POST", "/api/v1/forward", .json(201, Self.sentSummaryJSON))
        let client = Self.makeClient(server)
        let outbox = OutboxService(api: client)

        let sent = try await outbox.send(
            ComposeDraft(
                mode: .forward(messageID: "msg_01"),
                fromAddress: "support@example.com",
                to: ["ada@example.net"],
                subject: "Fwd: Invoice question",
                body: "See below."
            )
        )

        #expect(sent.id == "msg_fwd")
        #expect(server.requests(path: "/api/v1/send").isEmpty, "The forward still went through /send")
        let body = try #require(server.requests(path: "/api/v1/forward").first?.compactBodyText)
        #expect(body.contains(#""messageId":"msg_01""#))
        #expect(body.contains(#""from":"support@example.com""#))
        #expect(body.contains(#""to":["ada@example.net"]"#))
        // Herald sends only the authored text; the server appends the original.
        // `compactBodyText` strips ALL whitespace, the body's spaces included.
        #expect(body.contains(#""text":"Seebelow.""#))
        #expect(body.contains(#""includeOriginalAttachments":true"#))
    }

    /// A forward with no server draft at all is the exact case that used to lose
    /// the forwarded content — it must still name the message and must NOT create
    /// a draft just to have somewhere to put the link.
    @Test("An unsaved forward is sent without a draft round trip")
    func unsavedForwardNeedsNoDraft() async throws {
        let server = FakeServer()
        server.route("POST", "/api/v1/forward", .json(201, Self.sentSummaryJSON))

        _ = try await OutboxService(api: Self.makeClient(server)).send(
            ComposeDraft(
                mode: .forward(messageID: "msg_01"),
                fromAddress: "support@example.com",
                to: ["ada@example.net"],
                subject: "Fwd: Invoice question",
                body: ""
            )
        )

        #expect(server.requests(path: "/api/v1/drafts").isEmpty)
        let body = try #require(server.requests(path: "/api/v1/forward").first?.compactBodyText)
        #expect(body.contains(#""messageId":"msg_01""#))
    }

    /// `ForwardInput.subject` has `minLength: 1`, so an emptied subject field has
    /// to be omitted (the server then derives `Fwd: …`) rather than sent as "".
    /// Whitespace-only is the same case: the server's schema is
    /// `z.string().trim().min(1)`, so `"   "` is a 400, not an empty subject.
    @Test("An empty forward subject is omitted so the server derives it", arguments: ["", "   "])
    func emptyForwardSubjectIsOmitted(subject: String) async throws {
        let server = FakeServer()
        server.route("POST", "/api/v1/forward", .json(201, Self.sentSummaryJSON))

        _ = try await OutboxService(api: Self.makeClient(server)).send(
            ComposeDraft(
                mode: .forward(messageID: "msg_01"),
                fromAddress: "support@example.com",
                to: ["ada@example.net"],
                subject: subject,
                body: "fyi"
            )
        )

        let body = try #require(server.requests(path: "/api/v1/forward").first?.compactBodyText)
        #expect(!body.contains(#""subject""#))
    }

    /// A forward that WAS autosaved must still delete its draft after sending —
    /// `/forward` has no `draftId`, so the server does not consume it and an
    /// undeleted draft would sit in the Drafts folder forever.
    @Test("A saved forward's draft is deleted after the send")
    func savedForwardDeletesItsDraft() async throws {
        let draftJSON = """
        {"id":"dft_1","version":1,"updatedAt":"2026-09-04T10:00:00.000Z","attachments":[],
         "mailboxId":null,"replyToMessageId":null,"forwardOfMessageId":"msg_01",
         "from":"support@example.com","to":["ada@example.net"],"cc":[],"bcc":[],
         "subject":"Fwd: Invoice question","text":"See below.","html":"",\(Fixtures.draftSignatureAndLabelsJSON)}
        """
        let server = FakeServer()
        server.route("POST", "/api/v1/drafts", .json(201, draftJSON))
        server.route("POST", "/api/v1/forward", .json(201, Self.sentSummaryJSON))
        server.route("DELETE", "/api/v1/drafts/dft_1", .json(204, ""))
        let outbox = OutboxService(api: Self.makeClient(server))

        let saved = try await outbox.saveDraft(
            ComposeDraft(
                mode: .forward(messageID: "msg_01"),
                fromAddress: "support@example.com",
                to: ["ada@example.net"],
                subject: "Fwd: Invoice question",
                body: "See below."
            )
        )
        _ = try await outbox.send(saved)

        #expect(server.requests(path: "/api/v1/drafts/dft_1").count { $0.method == "DELETE" } == 1)
    }
}
