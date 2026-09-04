import Foundation
import Testing
@testable import HeraldKit

/// The delta-sync wire contract: the `Link` cursor on `GET /messages`, the
/// `GET /changes` envelope, and the two failure modes the engine branches on
/// (410 expired cursor, 404 route-missing on an older server).
@Suite struct ChangesAPITests {
    private func makeClient(_ server: FakeServer) -> HQBaseAPIClient {
        HQBaseAPIClient(origin: FakeServer.origin, tokens: FakeTokenProvider(), session: server.makeSession())
    }

    private static let summaryJSON = """
    {
      "id": "msg_01",
      "threadId": "thr_09",
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
      "createdAt": "2026-08-14T09:30:01.000Z"
    }
    """

    // MARK: - Link header

    /// The cursor is NOT a body field: dropping the header parse (or reading the
    /// URL instead of its `cursor` query item) silently turns every paginated
    /// listing into a one-page listing. Fails on any of those.
    @Test("A Link rel=next header yields the cursor query item")
    func linkHeaderProducesCursor() async throws {
        let server = FakeServer()
        server.route(
            "GET",
            "/api/v1/messages",
            .json(
                200,
                "[\(Self.summaryJSON)]",
                headers: [
                    "Link": #"<https://mail.test.invalid/api/v1/messages?folder=inbox&limit=100&cursor=m1%3Aabc>; rel="next""#
                ]
            )
        )

        let page = try await makeClient(server).listMessages(
            folder: .inbox,
            mailboxID: nil,
            search: nil,
            limit: 100,
            cursor: nil
        )

        #expect(page.messages.map(\.id) == ["msg_01"])
        #expect(page.nextCursor == "m1:abc", "the cursor must be percent-decoded out of the link target")
    }

    /// The last page carries no header at all. Fails if absence is treated as an
    /// error or produces a non-nil cursor (an infinite page-walk).
    @Test("No Link header means no next page")
    func absentLinkHeaderEndsTheWalk() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/messages", .json(200, "[\(Self.summaryJSON)]"))

        let page = try await makeClient(server).listMessages(
            folder: nil, mailboxID: nil, search: nil, limit: nil, cursor: nil
        )
        #expect(page.messages.count == 1)
        #expect(page.nextCursor == nil)
    }

    /// A header we cannot parse must degrade to "last page", never throw: a
    /// proxy that rewrites Link would otherwise break every listing.
    @Test(
        "A malformed or non-next Link header is ignored, not fatal",
        arguments: [
            "garbage",
            "<https://mail.test.invalid/api/v1/messages?folder=inbox>; rel=\"next\"",
            "<https://mail.test.invalid/api/v1/messages?cursor=m1>; rel=\"prev\"",
            "<;rel=next",
        ]
    )
    func malformedLinkHeaderIsIgnored(header: String) async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/messages", .json(200, "[\(Self.summaryJSON)]", headers: ["Link": header]))

        let page = try await makeClient(server).listMessages(
            folder: nil, mailboxID: nil, search: nil, limit: nil, cursor: nil
        )
        #expect(page.messages.count == 1, "a bad Link header must not lose the page body")
        #expect(page.nextCursor == nil, "header \(header) should not yield a cursor")
    }

    /// Fails if `limit`/`cursor` are dropped or renamed on the wire — the server
    /// would then silently answer page 1 forever.
    @Test("limit and cursor reach the wire on GET /messages")
    func paginationParametersReachTheWire() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/messages", .json(200, "[]"))

        _ = try await makeClient(server).listMessages(
            folder: .inbox, mailboxID: nil, search: nil, limit: 100, cursor: "m1:abc"
        )
        let query = try #require(server.requests(path: "/api/v1/messages").first?.query)
        #expect(query.contains("limit=100"))
        #expect(query.contains("cursor=m1"))
    }

    // MARK: - Changes envelope

    /// Both `oneOf` variants in one page. Fails if the discriminator is ignored
    /// (a delete decoded as an upsert, or vice versa) or a variant is dropped.
    @Test("A changes page decodes upsert and delete entries into the DTO enum")
    func changesEnvelopeDecodesBothVariants() async throws {
        let server = FakeServer()
        server.route(
            "GET",
            "/api/v1/changes",
            .json(
                200,
                """
                {
                  "changes": [
                    {"type":"upsert","message":\(Self.summaryJSON)},
                    {"type":"delete","messageId":"msg_gone","mailboxId":"mbx_support"}
                  ],
                  "nextCursor": "c1:2",
                  "hasMore": true
                }
                """
            )
        )

        let page = try await makeClient(server).changes(cursor: "c1:1", limit: 100)

        #expect(page.nextCursor == "c1:2")
        #expect(page.hasMore)
        #expect(page.changes.count == 2)
        guard case .upsert(let summary) = page.changes.first else {
            Issue.record("first entry must decode as an upsert, got \(String(describing: page.changes.first))")
            return
        }
        #expect(summary.id == "msg_01")
        guard case .delete(let messageID, let mailboxID) = page.changes.last else {
            Issue.record("second entry must decode as a delete, got \(String(describing: page.changes.last))")
            return
        }
        #expect(messageID == "msg_gone")
        #expect(mailboxID == "mbx_support")
    }

    /// Upstream 1.3.4 made the tombstone's `mailboxId` NULLABLE (owner-only
    /// unassigned mail). Before this, `MessageChange.delete` carried a
    /// non-optional String and the whole page failed to decode — the journal
    /// would have stalled on the first such deletion.
    @Test("A delete tombstone with a null mailboxId still decodes")
    func deleteTombstoneAcceptsNullMailbox() async throws {
        let server = FakeServer()
        server.route(
            "GET",
            "/api/v1/changes",
            .json(
                200,
                """
                {
                  "changes": [{"type":"delete","messageId":"msg_gone","mailboxId":null}],
                  "nextCursor": "c1:2",
                  "hasMore": false
                }
                """
            )
        )

        let page = try await makeClient(server).changes(cursor: "c1:1", limit: 100)

        guard case .delete(let messageID, let mailboxID) = page.changes.first else {
            Issue.record("expected a delete, got \(String(describing: page.changes.first))")
            return
        }
        #expect(messageID == "msg_gone")
        #expect(mailboxID == nil)
    }

    /// A checkpoint is "no cursor at all". Sending `cursor=` (or any value) makes
    /// the server replay history instead of handing back the high-water mark, so
    /// the absence of the parameter is the contract. Fails if it appears.
    @Test("A checkpoint request sends no cursor parameter")
    func checkpointSendsNoCursor() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/changes", .json(200, #"{"changes":[],"nextCursor":"chk_7","hasMore":false}"#))

        let page = try await makeClient(server).changesCheckpoint()

        #expect(page.changes.isEmpty)
        #expect(page.nextCursor == "chk_7")
        let query = server.requests(path: "/api/v1/changes").first?.query ?? ""
        #expect(!query.contains("cursor"), "checkpoint must omit the cursor entirely, sent: \(query)")
    }

    /// 410 is the only status that means "re-bootstrap". Before the dedicated
    /// case it fell into `.server(code:)` and the engine had to string-match the
    /// code to recover. Fails if 410 stops mapping to `.cursorExpired`.
    @Test("410 CHANGE_CURSOR_EXPIRED maps to .cursorExpired")
    func expiredCursorMapsToItsOwnCase() async throws {
        let server = FakeServer()
        server.route(
            "GET",
            "/api/v1/changes",
            .error(410, code: "CHANGE_CURSOR_EXPIRED", message: "cursor is older than the journal")
        )

        await #expect(throws: MailAPIError.cursorExpired) {
            _ = try await makeClient(server).changes(cursor: "ancient", limit: nil)
        }
    }

    /// 410 is documented but not yet reachable: the LIVE 1.3.4 server answers a
    /// foreign or out-of-range cursor with **400 INVALID_CHANGE_CURSOR** (410 is
    /// reserved for a retention policy it does not have yet). Verified by hand
    /// against localhost:8787 on 2026-09-04.
    ///
    /// Fails if that 400 goes back to being a generic server error: the cursor is
    /// persisted in the cache, so an unrecoverable one is UNRECOVERABLE — every
    /// pass fails on it, forever, and only deleting the cache would fix it.
    @Test(
        "A rejected cursor maps to .cursorExpired whichever status the server used",
        arguments: [(400, "INVALID_CHANGE_CURSOR"), (410, "CHANGE_CURSOR_EXPIRED")]
    )
    func rejectedCursorsAllRebootstrap(status: Int, code: String) async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/changes", .error(status, code: code, message: "no good"))

        await #expect(throws: MailAPIError.cursorExpired) {
            _ = try await makeClient(server).changes(cursor: "foreign", limit: nil)
        }
    }

    /// …but a 400 that is NOT about the cursor must stay an ordinary failure:
    /// re-bootstrapping the whole account on a bad `limit` would turn a client
    /// bug into a full re-listing on every pass.
    @Test("A 400 that is not about the cursor is not a re-bootstrap")
    func otherBadRequestsAreOrdinaryFailures() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/changes", .error(400, code: "INVALID_LIMIT", message: "bad limit"))

        await #expect(throws: MailAPIError.server(code: "INVALID_LIMIT", message: "bad limit")) {
            _ = try await makeClient(server).changes(cursor: "c1", limit: 9_000)
        }
    }

    /// The owner's instance is 1.1.2: `/api/v1/changes` does not exist there and
    /// answers 404. The engine's fallback keys on exactly `.notFound`, so a 404
    /// that arrived as `.server(code:)` would leave sync permanently broken
    /// against every pre-journal server.
    @Test("A server without the route surfaces .notFound so the engine can fall back")
    func missingRouteIsNotFound() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/changes", .error(404, code: "NOT_FOUND", message: "no such route"))

        await #expect(throws: MailAPIError.notFound) {
            _ = try await makeClient(server).changes(cursor: nil, limit: nil)
        }
    }
}
