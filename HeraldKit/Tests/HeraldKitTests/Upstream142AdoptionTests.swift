import Foundation
import Testing
@testable import HeraldKit

/// The surface Herald picked up from upstream 1.4.2: `includeLabels`, send
/// idempotency keys, signature management, and the explicit OAuth scope list.
///
/// Everything that touches HTTP is asserted ON THE WIRE (URLProtocol fake server)
/// rather than against a fake client, for the same reason as
/// ``Upstream134AdoptionTests``: the bug class here is "the DTO was right and the
/// request was not" — a label embed nobody asked for, an idempotency key that
/// never left the process, a PATCH body the generator quietly emptied out.
@Suite struct Upstream142AdoptionTests {
    private static func makeClient(_ server: FakeServer, includeLabels: Bool = false) -> HQBaseAPIClient {
        HQBaseAPIClient(
            origin: FakeServer.origin,
            tokens: FakeTokenProvider(),
            session: server.makeSession(),
            includeLabels: includeLabels
        )
    }

    /// A `MessageSummary` row. `labels` is spliced in verbatim so a test can send
    /// the key, omit it, or send it empty — the three cases that must stay distinct.
    private static func summaryJSON(id: String = "msg_01", labels: String? = nil) -> String {
        let labelsKey = labels.map { ",\"labels\":\($0)" } ?? ""
        return """
        {"id":"\(id)","threadId":"thr_01","mailboxId":"mbx_support","direction":"inbound",
         "folder":"inbox","fromAddress":"ada@example.net","to":["support@example.com"],
         "subject":"Invoice question","snippet":"…","receivedAt":"2026-09-19T09:30:00.000Z",
         "sentAt":null,"readAt":null,"starredAt":null,"hasAttachments":false,
         "createdAt":"2026-09-19T09:30:01.000Z"\(labelsKey)}
        """
    }

    /// `nonisolated` so it can be read from a `@Test(arguments:)` list, which the
    /// macro expands outside the suite's implicit MainActor isolation.
    private nonisolated static let labelJSON = """
    [{"id":"lbl_1","name":"Billing","color":"amber",
      "createdAt":"2026-09-01T00:00:00.000Z","updatedAt":"2026-09-01T00:00:00.000Z"}]
    """

    private static func signatureJSON(id: String = "sig_1", name: String = "Personal") -> String {
        """
        {"id":"\(id)","name":"\(name)","html":"<p>Best</p>","text":"Best",
         "scope":"mailbox","scopeId":"mbx_support","scopeLabel":"Support","isDefault":true,
         "createdAt":"2026-09-01T00:00:00.000Z","updatedAt":"2026-09-01T00:00:00.000Z"}
        """
    }

    private static let sentSummaryJSON = summaryJSON(id: "msg_sent")

    // MARK: - includeLabels on the wire

    /// Fails if the parameter leaks onto requests from a client that did not ask
    /// for labels. The embed costs a label join per row server-side, and the whole
    /// point of the client-level switch is that ONE place decides — a hardcoded
    /// `includeLabels=true`, or a `false` spelled out on the query, would make every
    /// Herald request differ from what a pre-1.4.2 client sends for no gain.
    @Test("A client that did not ask for labels sends no includeLabels parameter")
    func includeLabelsIsAbsentByDefault() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/messages", .json(200, "[\(Self.summaryJSON())]"))

        _ = try await Self.makeClient(server).listMessages(folder: .inbox)

        let query = try #require(server.requests(path: "/api/v1/messages").first).query ?? ""
        #expect(!query.contains("includeLabels"))
    }

    /// Fails if any of the six label-capable operations forgets the parameter —
    /// which would look like "the server stopped embedding labels" to U2's sync,
    /// i.e. every message silently losing its chips on that path only.
    @Test("Every label-capable operation carries includeLabels=true when the client asks")
    func includeLabelsReachesEveryOperation() async throws {
        let server = FakeServer()
        let row = Self.summaryJSON(labels: Self.labelJSON)
        let detail = """
        {"id":"msg_01","threadId":"thr_01","mailboxId":"mbx_support","direction":"inbound",
         "folder":"inbox","fromAddress":"ada@example.net","to":["support@example.com"],
         "subject":"Invoice question","snippet":"…","receivedAt":"2026-09-19T09:30:00.000Z",
         "sentAt":null,"readAt":null,"starredAt":null,"hasAttachments":false,
         "createdAt":"2026-09-19T09:30:01.000Z","labels":\(Self.labelJSON),
         "cc":[],"bcc":[],"textBody":"Hi","htmlAvailable":false,"references":[],"attachments":[]}
        """
        server.route("GET", "/api/v1/messages", .json(200, "[\(row)]"))
        server.route("GET", "/api/v1/messages/msg_01", .json(200, detail))
        server.route("GET", "/api/v1/messages/msg_01/thread", .json(200, "[\(detail)]"))
        server.route("POST", "/api/v1/messages/msg_01/read", .json(200, row))
        server.route("GET", "/api/v1/conversations", .json(200, """
        {"conversations":[{"id":"msg_01","threadId":"thr_01","mailboxId":"mbx_support",
          "direction":"inbound","folder":"inbox","fromAddress":"ada@example.net",
          "to":["support@example.com"],"subject":"Invoice question","snippet":"…",
          "receivedAt":"2026-09-19T09:30:00.000Z","sentAt":null,"readAt":null,"starredAt":null,
          "hasAttachments":false,"createdAt":"2026-09-19T09:30:01.000Z","labels":\(Self.labelJSON),
          "isStarred":false,"messageCount":1,"unreadCount":1}],"nextCursor":null,"totalCount":1}
        """))
        server.route("GET", "/api/v1/changes", .json(200, """
        {"changes":[{"type":"upsert","message":\(row)}],"nextCursor":"c1","hasMore":false}
        """))

        let client = Self.makeClient(server, includeLabels: true)
        _ = try await client.listMessages(folder: .inbox)
        _ = try await client.message(id: "msg_01")
        _ = try await client.thread(messageID: "msg_01")
        _ = try await client.perform(.read, onMessage: "msg_01")
        _ = try await client.listConversations(folder: .inbox)
        _ = try await client.changes(cursor: "c0", limit: 50)

        let paths = [
            "/api/v1/messages",
            "/api/v1/messages/msg_01",
            "/api/v1/messages/msg_01/thread",
            "/api/v1/messages/msg_01/read",
            "/api/v1/conversations",
            "/api/v1/changes"
        ]
        for path in paths {
            let query = try #require(server.requests(path: path).first, "no request to \(path)").query ?? ""
            #expect(query.contains("includeLabels=true"), "\(path) asked without includeLabels")
        }
    }

    /// The label sweep names a single label and must keep doing so; fails if the
    /// sweep ever starts sending `labelIds`, which upstream ANDs rather than ORs.
    @Test("The per-label sweep still carries includeLabels and the singular labelId")
    func labelSweepCarriesIncludeLabels() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/messages", .json(200, "[\(Self.summaryJSON(labels: Self.labelJSON))]"))

        _ = try await Self.makeClient(server, includeLabels: true)
            .listMessages(labelID: "lbl_1", limit: 100, cursor: nil)

        let query = try #require(server.requests(path: "/api/v1/messages").first).query ?? ""
        #expect(query.contains("labelId=lbl_1"))
        #expect(!query.contains("labelIds"))
        #expect(query.contains("includeLabels=true"))
    }

    // MARK: - labels: nil vs []

    /// THE load-bearing distinction for U2. A row with no `labels` key says nothing
    /// about membership (old server, or nobody asked) and must NOT clear the cache;
    /// a row with `[]` says "no labels" and must. Mapping the absent key to `[]` —
    /// the obvious `?? []` — silently wipes every chip against a 1.3.4 server.
    @Test(
        "An absent labels key decodes to nil; a present one (even empty) decodes to an array",
        arguments: [
            (nil as String?, nil as Int?),
            ("[]", 0),
            (Self.labelJSON, 1)
        ]
    )
    func labelsPreserveTheAbsentDistinction(labels: String?, expectedCount: Int?) async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/messages", .json(200, "[\(Self.summaryJSON(labels: labels))]"))

        let page = try await Self.makeClient(server, includeLabels: true)
            .listMessages(folder: .inbox, mailboxID: nil, search: nil, limit: nil, cursor: nil)

        #expect(page.messages.first?.labels?.count == expectedCount)
        #expect((page.messages.first?.labels == nil) == (expectedCount == nil))
    }

    /// `MessageDetail` and `ConversationSummary` are `allOf[MessageSummary, …]`, so
    /// they get labels through the shared half. Fails if a future refactor maps the
    /// summary twice and drops the embed on one of the composite paths.
    @Test("MessageDetail carries the embedded labels of its summary half")
    func messageDetailCarriesLabels() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/messages/msg_01", .json(200, """
        {"id":"msg_01","threadId":"thr_01","mailboxId":"mbx_support","direction":"inbound",
         "folder":"inbox","fromAddress":"ada@example.net","to":["support@example.com"],
         "subject":"Invoice question","snippet":"…","receivedAt":"2026-09-19T09:30:00.000Z",
         "sentAt":null,"readAt":null,"starredAt":null,"hasAttachments":false,
         "createdAt":"2026-09-19T09:30:01.000Z","labels":\(Self.labelJSON),
         "cc":[],"bcc":[],"textBody":"Hi","htmlAvailable":false,"references":[],"attachments":[]}
        """))

        let detail = try await Self.makeClient(server, includeLabels: true).message(id: "msg_01")

        #expect(detail.summary.labels?.map(\.name) == ["Billing"])
    }

    /// `MessageDetail.replyTo` is new and OPTIONAL at 1.4.2. Fails if it is ever
    /// mapped with a `?? []` fallback: an older server sends no key, and an empty
    /// array there would read as "this message has no reply targets" — which is the
    /// difference between letting the server pick the recipients and sending none.
    @Test("replyTo is nil on a server that does not send it and an array when it does")
    func replyToPreservesTheAbsentDistinction() async throws {
        let base = """
        "id":"msg_01","threadId":"thr_01","mailboxId":"mbx_support","direction":"inbound",
        "folder":"inbox","fromAddress":"ada@example.net","to":["support@example.com"],
        "subject":"Invoice question","snippet":"…","receivedAt":"2026-09-19T09:30:00.000Z",
        "sentAt":null,"readAt":null,"starredAt":null,"hasAttachments":false,
        "createdAt":"2026-09-19T09:30:01.000Z","cc":[],"bcc":[],"textBody":"Hi",
        "htmlAvailable":false,"references":[],"attachments":[]
        """
        let server = FakeServer()
        server.route("GET", "/api/v1/messages/msg_01", .json(200, "{\(base)}"))
        server.route("GET", "/api/v1/messages/msg_02", .json(200, "{\(base),\"replyTo\":[\"billing@example.net\"]}"))
        let client = Self.makeClient(server)

        #expect(try await client.message(id: "msg_01").replyTo == nil)
        #expect(try await client.message(id: "msg_02").replyTo == ["billing@example.net"])
    }

    // MARK: - idempotencyKey

    /// Fails if the key is serialized when nobody set one. An `idempotencyKey: ""`
    /// or a key the client invents per attempt is worse than none: the server keys
    /// the stored send operation on it, so a wrong key turns a legitimate retry
    /// into a 409 `SEND_KEY_CONFLICT` or, worse, a second delivery.
    @Test("No idempotencyKey is serialized when the caller did not set one")
    func idempotencyKeyIsOmittedByDefault() async throws {
        let server = FakeServer()
        server.route("POST", "/api/v1/send", .json(201, Self.sentSummaryJSON))

        _ = try await Self.makeClient(server).send(
            SendInput(from: "support@example.com", to: ["ada@example.net"], subject: "Hi", text: "Hello")
        )

        let body = try #require(server.requests(path: "/api/v1/send").first).compactBodyText
        #expect(!body.contains("idempotencyKey"))
    }

    /// One case per route, because each has its own generated body type and its own
    /// hand-written mapping — the plumbing can be dropped on exactly one of them.
    /// Forward is the case that matters most: it takes no `draftId`, so the key is
    /// its ONLY retry identity.
    @Test("Every send route carries the idempotency key when set", arguments: ["/api/v1/send", "/api/v1/reply", "/api/v1/forward"])
    func idempotencyKeyReachesEverySendRoute(path: String) async throws {
        let server = FakeServer()
        server.route("POST", path, .json(201, Self.sentSummaryJSON))
        let client = Self.makeClient(server)

        switch path {
        case "/api/v1/send":
            _ = try await client.send(SendInput(
                from: "support@example.com",
                to: ["ada@example.net"],
                subject: "Hi",
                text: "Hello",
                idempotencyKey: "key-123"
            ))
        case "/api/v1/reply":
            _ = try await client.reply(ReplyInput(
                messageID: "msg_01",
                from: "support@example.com",
                text: "Hello",
                idempotencyKey: "key-123"
            ))
        default:
            _ = try await client.forward(ForwardInput(
                messageID: "msg_01",
                from: "support@example.com",
                to: ["ada@example.net"],
                text: "Hello",
                idempotencyKey: "key-123"
            ))
        }

        let body = try #require(server.requests(path: path).first).compactBodyText
        #expect(body.contains(#""idempotencyKey":"key-123""#))
    }

    /// U3 matches on the CODE, not the status: both idempotency outcomes are the
    /// same HTTP class as a dozen unrelated failures. Fails if the middleware ever
    /// starts collapsing 409/503 into a code-less error, which would leave U3 unable
    /// to tell "you already sent this" from "the send storage is not ready".
    @Test("409 and 503 send failures surface with the server's own error code", arguments: [
        (409, "SEND_KEY_CONFLICT"),
        (503, "SEND_RECOVERY_UNAVAILABLE"),
        (503, "SEND_STORAGE_NOT_READY")
    ])
    func sendFailuresCarryTheServerCode(status: Int, code: String) async throws {
        let server = FakeServer()
        server.route("POST", "/api/v1/send", .error(status, code: code, message: "Do not send it again"))

        await #expect(throws: MailAPIError.server(code: code, message: "Do not send it again")) {
            try await Self.makeClient(server).send(
                SendInput(from: "support@example.com", to: ["ada@example.net"], subject: "Hi", text: "Hello")
            )
        }
    }

    // MARK: - Signature management

    /// Fails on a wrong verb, a wrong path, or a scope pair serialized as anything
    /// other than `{"type":…,"id":…}` — the create route 400s on all three, and none
    /// of them is visible from the Swift call site.
    @Test("createSignature POSTs to /signatures with the scope as a {type,id} object")
    func createSignatureRequestShape() async throws {
        let server = FakeServer()
        server.route("POST", "/api/v1/signatures", .json(201, Self.signatureJSON()))

        let created = try await Self.makeClient(server).createSignature(CreateSignatureInput(
            name: "Personal",
            html: "<p>Best</p>",
            scope: SignatureScopeRef(type: .mailbox, id: "mbx_support"),
            isDefault: true
        ))

        let request = try #require(server.requests(path: "/api/v1/signatures").first)
        #expect(request.method == "POST")
        // Key ORDER inside the nested object is the encoder's business; what matters
        // is that `scope` is an object carrying both `type` and `id` — a flattened
        // `"scope":"mailbox"` (the shape of `Signature.scope`) is a 400.
        #expect(request.compactBodyText.contains(#""scope":{"#))
        #expect(request.compactBodyText.contains(#""type":"mailbox""#))
        #expect(request.compactBodyText.contains(#""id":"mbx_support""#))
        #expect(request.compactBodyText.contains(#""isDefault":true"#))
        #expect(created.id == "sig_1")
    }

    /// `/signatures/manage` is a DIFFERENT question from `/signatures?from=` — what
    /// may be edited, not what may be used from one address. Fails if the two are
    /// ever wired to the same route, which would silently show the wrong list.
    @Test("listManageableSignatures reads /signatures/manage, not /signatures")
    func listManageableSignaturesRequestShape() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/signatures/manage", .json(200, "[\(Self.signatureJSON())]"))

        let signatures = try await Self.makeClient(server).listManageableSignatures()

        #expect(signatures.map(\.id) == ["sig_1"])
        #expect(server.requests(path: "/api/v1/signatures").isEmpty)
        #expect(server.requests(path: "/api/v1/signatures/manage").first?.method == "GET")
    }

    /// THE generator trap this phase hit. Upstream spells "at least one of
    /// name/html/isDefault" as a top-level `anyOf` over `required`;
    /// swift-openapi-generator 1.7 reads that as three separate schemas, warns the
    /// properties "only appear in the required list", and emits three EMPTY structs
    /// — so the PATCH body would encode as `{}` and every edit would 400. This test
    /// fails the moment `scripts/vendor-openapi.py` stops collapsing that `anyOf`.
    @Test("updateSignature PATCHes a body that actually contains the changed fields")
    func updateSignatureSerializesItsFields() async throws {
        let server = FakeServer()
        server.route("PATCH", "/api/v1/signatures/sig_1", .json(200, Self.signatureJSON(name: "Renamed")))

        let updated = try await Self.makeClient(server).updateSignature(
            id: "sig_1",
            with: UpdateSignatureInput(name: "Renamed", isDefault: false)
        )

        let request = try #require(server.requests(path: "/api/v1/signatures/sig_1").first)
        #expect(request.method == "PATCH")
        #expect(request.compactBodyText.contains(#""name":"Renamed""#))
        #expect(request.compactBodyText.contains(#""isDefault":false"#))
        // Omitted fields must stay omitted: PATCH is a partial update, and an
        // explicit `"html":null` would be a 400 rather than "leave it alone".
        #expect(!request.compactBodyText.contains("html"))
        #expect(updated.name == "Renamed")
    }

    /// An empty patch is a guaranteed 400 `SIGNATURE_INVALID`. Fails if the client
    /// ever spends the round trip to be told so — which, with no request recorded,
    /// is also the only way to prove the guard runs before the transport.
    @Test("An update with no fields set fails locally instead of round-tripping")
    func emptyUpdateIsRejectedWithoutARequest() async throws {
        let server = FakeServer()
        server.route("PATCH", "/api/v1/signatures/sig_1", .json(200, Self.signatureJSON()))

        await #expect(throws: MailAPIError.self) {
            try await Self.makeClient(server).updateSignature(id: "sig_1", with: UpdateSignatureInput())
        }
        #expect(server.requests(path: "/api/v1/signatures/sig_1").isEmpty)
    }

    /// 204 with no body. Fails if the client starts expecting JSON back, which turns
    /// a successful delete into a decoding error and leaves the row on screen.
    @Test("deleteSignature accepts a 204 with no body")
    func deleteSignatureRequestShape() async throws {
        let server = FakeServer()
        server.route("DELETE", "/api/v1/signatures/sig_1", FakeResponse(status: 204))

        try await Self.makeClient(server).deleteSignature(id: "sig_1")

        #expect(server.requests(path: "/api/v1/signatures/sig_1").first?.method == "DELETE")
    }

    /// An account consented before Herald asked for `signatures:manage` gets 403
    /// `insufficient_scope`. Fails if that is flattened into a generic server error,
    /// which U4 cannot tell from "the editor is broken" and would retry forever.
    @Test("An unscoped account's 403 surfaces as insufficientScope, not a generic failure")
    func managementWithoutScopeSurfacesInsufficientScope() async throws {
        let server = FakeServer()
        server.route(
            "GET",
            "/api/v1/signatures/manage",
            .error(
                403,
                code: "FORBIDDEN",
                message: "Insufficient scope",
                headers: ["WWW-Authenticate": #"Bearer error="insufficient_scope", scope="signatures:manage""#]
            )
        )

        await #expect(throws: MailAPIError.insufficientScope("signatures:manage")) {
            try await Self.makeClient(server).listManageableSignatures()
        }
    }

    // MARK: - OAuth scopes

    /// Fails if Herald goes back to requesting whatever the resource advertises.
    /// `scopes_supported` is the SERVER's list, not Herald's: a scope added by a
    /// future release would then appear on the consent screen — the user granting
    /// a permission the app has no code for — without anyone deciding to ask.
    @Test("An advertised scope Herald does not use is never requested")
    func unknownAdvertisedScopesAreNotRequested() {
        let scopes = OAuthDiscovery.requestedScopes(
            advertised: ["mail:read", "mail:write", "mail:send", "signatures:manage", "admin:everything"]
        )

        #expect(scopes == ["mail:read", "mail:write", "mail:send", "signatures:manage", "offline_access"])
    }

    /// Fails if Herald asks a 1.3.4 server for `signatures:manage`. That server does
    /// not advertise it and rejects the authorize call outright — not a degraded
    /// signatures editor but no sign-in at all, for every older deployment.
    @Test("A server that does not advertise signatures:manage is not asked for it")
    func olderServersAreNotAskedForSignatureManagement() {
        let scopes = OAuthDiscovery.requestedScopes(advertised: ["mail:read", "mail:write", "mail:send"])

        #expect(scopes == ["mail:read", "mail:write", "mail:send", "offline_access"])
        #expect(!scopes.contains("signatures:manage"))
    }

    /// `offline_access` is deliberately absent from `scopes_supported` (it is not an
    /// API permission), and without it the server mints no refresh token and the
    /// sign-in dies at the first access-token expiry — Herald issue #1. Intersecting
    /// the advertised list must never take it out again.
    @Test("offline_access survives the intersection even though no server advertises it")
    func offlineAccessIsAlwaysRequested() {
        #expect(OAuthDiscovery.requestedScopes(advertised: ["mail:read"]) == ["mail:read", "offline_access"])
        // No metadata at all falls back to the conservative pre-1.4.2 set: with
        // nothing advertised there is no way to tell 1.4.2 from 1.3.4.
        #expect(OAuthDiscovery.requestedScopes(advertised: []) == OAuthDiscovery.defaultScopes)
        #expect(!OAuthDiscovery.requestedScopes(advertised: []).contains("signatures:manage"))
    }
}
