import Foundation
import Testing
@testable import HeraldKit

/// The wire contract of server-side search: `GET /conversations` has to carry the
/// needle AND the scope, and its cursor has to come back so the caller can page.
///
/// Upstream `search=` is a `LIKE %term%` scoped to the requested folder/mailbox
/// — a request that drops `folder` or `mailboxId` silently searches the wrong
/// (wider) set and the UI unions rows from folders the user is not looking at.
@Suite struct ConversationSearchAPITests {
    private func makeClient(_ server: FakeServer) -> HQBaseAPIClient {
        HQBaseAPIClient(origin: FakeServer.origin, tokens: FakeTokenProvider(), session: server.makeSession())
    }

    private static func page(_ ids: [String], nextCursor: String?) -> String {
        let rows = ids.map { id in
            """
            {
              "id": "m_\(id)",
              "threadId": "\(id)",
              "mailboxId": "mbx_support",
              "direction": "inbound",
              "folder": "inbox",
              "fromAddress": "ada@example.net",
              "to": ["support@example.com"],
              "subject": "Invoice question",
              "snippet": "Hi…",
              "receivedAt": "2026-08-14T09:30:00.000Z",
              "sentAt": null,
              "readAt": null,
              "starredAt": null,
              "hasAttachments": false,
              "createdAt": "2026-08-14T09:30:01.000Z",
              "isStarred": false,
              "messageCount": 1,
              "unreadCount": 1
            }
            """
        }
        let cursor = nextCursor.map { "\"\($0)\"" } ?? "null"
        return """
        {"conversations":[\(rows.joined(separator: ","))],"nextCursor":\(cursor),"totalCount":2}
        """
    }

    /// Fails if the needle, the folder or the mailbox is dropped from the query —
    /// each of which produces a plausible-looking but wrongly scoped result set.
    @Test("A scoped search sends search, folder and mailboxId")
    func searchRequestCarriesNeedleAndScope() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/conversations", .json(200, Self.page(["thr_1"], nextCursor: nil)))

        _ = try await makeClient(server).listConversations(
            folder: .archived,
            mailboxID: "mbx_support",
            search: "invoice question",
            cursor: nil
        )

        let query = try #require(server.requests(path: "/api/v1/conversations").first?.query)
        let items = try #require(
            URLComponents(string: "https://x.invalid?\(query)")?.queryItems
        )
        let byName = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        #expect(byName["search"] == "invoice question")
        #expect(byName["folder"] == "archived")
        #expect(byName["mailboxId"] == "mbx_support")
        // No cursor on the first page — sending an empty one is a 400 upstream.
        #expect(items.contains { $0.name == "cursor" } == false)
    }

    /// Fails if `nextCursor` stops being read off the body (conversations do NOT
    /// use the `Link` header that `/messages` does), which would turn every
    /// server search into a one-page search with no sign that anything is missing.
    @Test("The body's nextCursor is what pages a search")
    func searchPagesByBodyCursor() async throws {
        let server = FakeServer()
        server.route(
            "GET",
            "/api/v1/conversations",
            .json(200, Self.page(["thr_1"], nextCursor: "c2")),
            .json(200, Self.page(["thr_2"], nextCursor: nil))
        )
        let client = makeClient(server)

        let first = try await client.listConversations(
            folder: .inbox, mailboxID: nil, search: "invoice", cursor: nil
        )
        #expect(first.nextCursor == "c2")
        #expect(first.hasMore)

        let second = try await client.listConversations(
            folder: .inbox, mailboxID: nil, search: "invoice", cursor: first.nextCursor
        )
        #expect(second.nextCursor == nil)
        #expect(second.conversations.map(\.id) == ["thr_2"])

        let cursors = server.requests(path: "/api/v1/conversations").map { request in
            URLComponents(string: "https://x.invalid?\(request.query ?? "")")?
                .queryItems?.first { $0.name == "cursor" }?.value
        }
        #expect(cursors == [nil, "c2"])
    }
}
