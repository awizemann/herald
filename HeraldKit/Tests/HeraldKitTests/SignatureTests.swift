import Foundation
import Testing
@testable import HeraldKit

/// Signatures (upstream 1.3.4).
///
/// The contract these pin down, verified against `worker/features/signatures`:
/// the client sends a SELECTION (`automatic` / `selected` / `none`), the server
/// resolves it into a snapshot and appends the signature to the outgoing body
/// itself (`assembleMessageBody`). Herald must therefore never concatenate one —
/// the same invariant as the quoted original — and must state its selection on
/// every draft write, because an omitted one is not "keep the default".
@Suite struct SignatureTests {
    private static func makeClient(_ server: FakeServer) -> HQBaseAPIClient {
        HQBaseAPIClient(
            origin: FakeServer.origin,
            tokens: FakeTokenProvider(),
            session: server.makeSession()
        )
    }

    private static let candidatesJSON = """
    {
      "automaticSignatureId": "sig_mailbox",
      "signatures": [
        {
          "id": "sig_mailbox",
          "name": "Support",
          "html": "<p>Support Team</p>",
          "text": "Support Team",
          "scope": "mailbox",
          "scopeId": "mbx_support",
          "scopeLabel": "support@example.com",
          "isDefault": true,
          "createdAt": "2026-08-01T10:00:00.000Z",
          "updatedAt": "2026-08-02T10:00:00.000Z"
        },
        {
          "id": "sig_personal",
          "name": "Ada",
          "html": "<p>Ada Lovelace</p>",
          "text": "Ada Lovelace",
          "scope": "user",
          "scopeId": "usr_1",
          "scopeLabel": "Ada",
          "isDefault": false,
          "createdAt": "2026-08-01T10:00:00.000Z",
          "updatedAt": "2026-08-01T10:00:00.000Z"
        }
      ]
    }
    """

    private static func draftJSON(signature: String, version: Int = 1) -> String {
        """
        {"id":"drf_1","version":\(version),"updatedAt":"2026-09-04T10:00:00.000Z",
         "mailboxId":"mbx_support","from":"support@example.com","to":["ada@example.net"],
         "cc":[],"bcc":[],"subject":"Hello","text":"Hi","html":"",
         "attachments":[],"labels":[],"signature":\(signature)}
        """
    }

    private static let sentSummaryJSON = """
    {"id":"msg_sent","threadId":"thr_1","mailboxId":"mbx_support","direction":"outbound",
     "folder":"sent","fromAddress":"support@example.com","to":["ada@example.net"],
     "subject":"Hello","snippet":"Hi","receivedAt":null,"sentAt":"2026-09-04T10:00:00.000Z",
     "readAt":null,"starredAt":null,"hasAttachments":false,"createdAt":"2026-09-04T10:00:00.000Z"}
    """

    // MARK: - GET /signatures

    /// The route is per-ADDRESS, not per-account: the server rejects a request
    /// without `from` (400 `SIGNATURE_INVALID`) and answers only with signatures
    /// usable from that exact address.
    @Test("Listing signatures sends the From address and maps every scope")
    func listsSignaturesForAnAddress() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/signatures", .json(200, Self.candidatesJSON))

        let candidates = try await Self.makeClient(server).signatures(from: "support@example.com")

        let request = try #require(server.requests(path: "/api/v1/signatures").first)
        #expect(request.query == "from=support@example.com")
        #expect(candidates.automaticSignatureID == "sig_mailbox")
        #expect(candidates.signatures.map(\.scope) == [.mailbox, .user])
        #expect(candidates.resolved(.automatic)?.name == "Support")
        #expect(candidates.resolved(.selected(id: "sig_personal"))?.text == "Ada Lovelace")
        #expect(candidates.resolved(.noSignature) == nil)
    }

    /// `automaticSignatureId` is nullable — an address with no default at any
    /// scope. `.automatic` then resolves to nothing rather than to the first row.
    @Test("A null automatic id resolves to no signature, not the first candidate")
    func nullAutomaticResolvesToNothing() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/signatures", .json(200, """
        {"automaticSignatureId":null,"signatures":[
          {"id":"sig_personal","name":"Ada","html":"<p>A</p>","text":"Ada","scope":"user",
           "scopeId":"usr_1","scopeLabel":"Ada","isDefault":false,
           "createdAt":"2026-08-01T10:00:00.000Z","updatedAt":"2026-08-01T10:00:00.000Z"}]}
        """))

        let candidates = try await Self.makeClient(server).signatures(from: "support@example.com")

        #expect(candidates.automaticSignatureID == nil)
        #expect(candidates.resolved(.automatic) == nil)
    }

    // MARK: - Drafts

    /// `Draft.signature` is the SNAPSHOT the server stored, and it is what a send
    /// naming this draft will use. Mapping it as anything else (or dropping it)
    /// leaves the composer showing a signature the message will not carry.
    @Test("A draft's stored snapshot maps, and editableContent restates it as a selection")
    func draftSnapshotMaps() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/drafts/drf_1", .json(200, Self.draftJSON(
            signature: #"{"mode":"selected","id":"sig_personal","name":"Ada","html":"<p>A</p>","text":"Ada"}"#
        )))

        let draft = try await Self.makeClient(server).draft(id: "drf_1")

        #expect(draft.signature.mode == .selected)
        #expect(draft.signature.id == "sig_personal")
        #expect(draft.signature.text == "Ada")
        #expect(draft.editableContent.signature == .selected(id: "sig_personal"))
    }

    /// A snapshot whose signature has been deleted keeps `mode: "selected"` with a
    /// null id. Re-sending that as `selected` would be a 400
    /// `SIGNATURE_NOT_AVAILABLE`, so it degrades to `automatic` — which is what
    /// the server itself does on the next save (`resolveDraftSignature`).
    @Test("A selected snapshot with no id degrades to the automatic selection")
    func danglingSnapshotDegradesToAutomatic() {
        let snapshot = SignatureSnapshot(mode: .selected, id: nil, name: "Gone", html: "", text: "Gone")
        #expect(SignatureSelection(snapshot) == .automatic)
        #expect(SignatureSelection(.empty) == .noSignature)
    }

    /// The regression this suite exists for as much as any: `drafts.signature_id`
    /// is `ON DELETE SET NULL`, so deleting a signature leaves its drafts with
    /// `{"mode":"selected","id":null}`. Upstream's `Draft` is
    /// `allOf[DraftInput, {…signature: SignatureSnapshot}]`, and `DraftInput`'s
    /// own `signature` is a `SignatureSelection` — so that ONE key was decoded
    /// twice, and a null id matched no selection case and failed the WHOLE draft.
    /// Herald's spec splits the response fields out as `DraftFields`; this test
    /// fails if a regenerated spec drops that split.
    @Test("A draft whose signature was deleted still decodes")
    func draftWithADeletedSignatureDecodes() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/drafts/drf_1", .json(200, Self.draftJSON(
            signature: #"{"mode":"selected","id":null,"name":"Gone","html":"","text":"Gone"}"#
        )))

        let draft = try await Self.makeClient(server).draft(id: "drf_1")

        #expect(draft.content.subject == "Hello")
        #expect(draft.signature.id == nil)
        // The next save asks for the address default rather than a 400.
        #expect(draft.editableContent.signature == .automatic)
    }

    /// Fails if the selection is dropped from the PATCH body: the server would
    /// then keep whatever snapshot the draft already had, so switching to "No
    /// signature" would silently not stick.
    @Test("Saving a draft sends the selection in the body")
    func draftSaveCarriesTheSelection() async throws {
        let server = FakeServer()
        server.route("PATCH", "/api/v1/drafts/drf_1", .json(200, Self.draftJSON(
            signature: #"{"mode":"none","id":null,"name":"","html":"","text":""}"#, version: 2
        )))

        var input = DraftInput(from: "support@example.com", subject: "Hello", text: "Hi", version: 1)
        input.signature = SignatureSelection.noSignature
        _ = try await Self.makeClient(server).updateDraft(id: "drf_1", with: input)

        let body = try #require(server.requests(path: "/api/v1/drafts/drf_1").first?.compactBodyText)
        #expect(try Self.signatureField(of: server, path: "/api/v1/drafts/drf_1") == ["mode": "none"])
        #expect(body.contains(#""subject":"Hello""#), "the rest of the draft still goes up")
    }

    // MARK: - Sending

    /// One test per send route: all three take a `signature` selection, and a
    /// forward is the one that CANNOT fall back on a stored draft snapshot
    /// (`POST /forward` has no `draftId`), so losing it there loses the signature.
    @Test("Send, reply and forward all carry the selection on the wire")
    func sendRoutesCarryTheSelection() async throws {
        let server = FakeServer()
        for path in ["/api/v1/send", "/api/v1/reply", "/api/v1/forward"] {
            server.route("POST", path, .json(201, Self.sentSummaryJSON))
        }
        let client = Self.makeClient(server)

        _ = try await client.send(SendInput(
            from: "support@example.com",
            to: ["ada@example.net"],
            subject: "Hello",
            text: "Hi",
            signature: .selected(id: "sig_personal")
        ))
        _ = try await client.reply(ReplyInput(
            messageID: "msg_01", from: "support@example.com", text: "Hi", signature: .automatic
        ))
        _ = try await client.forward(ForwardInput(
            messageID: "msg_01",
            from: "support@example.com",
            to: ["ada@example.net"],
            signature: .noSignature
        ))

        // Parsed, not string-matched: key order is a Codable detail, the FIELD is
        // the contract.
        #expect(try Self.signatureField(of: server, path: "/api/v1/send")
            == ["mode": "selected", "id": "sig_personal"])
        #expect(try Self.signatureField(of: server, path: "/api/v1/reply") == ["mode": "automatic"])
        #expect(try Self.signatureField(of: server, path: "/api/v1/forward") == ["mode": "none"])
    }

    /// The `signature` object of the first request to `path`, as plain strings.
    private static func signatureField(of server: FakeServer, path: String) throws -> [String: String] {
        let body = try #require(server.requests(path: path).first?.body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        return (json?["signature"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
    }

    // MARK: - Compose

    private static func candidates() -> SignatureCandidates {
        SignatureCandidates(
            automaticSignatureID: "sig_mailbox",
            signatures: [
                Signature(
                    id: "sig_mailbox", name: "Support", html: "<p>Support Team</p>", text: "Support Team",
                    scope: .mailbox, scopeID: "mbx_support", scopeLabel: "support@example.com",
                    isDefault: true, createdAt: .distantPast, updatedAt: .distantPast
                ),
                Signature(
                    id: "sig_personal", name: "Ada", html: "<p>Ada</p>", text: "Ada Lovelace",
                    scope: .user, scopeID: "usr_1", scopeLabel: "Ada",
                    isDefault: false, createdAt: .distantPast, updatedAt: .distantPast
                ),
            ]
        )
    }

    private static func outbox(_ api: FakeMailAPIClient) async -> OutboxService {
        await api.setSignatures(candidates(), from: "support@example.com")
        return OutboxService(api: api)
    }

    /// A new composer defaults to `.automatic`, so the first save stores the
    /// address's default signature. Defaulting to `.none` (the server's own
    /// behaviour for an omitted field) would mean Herald never applied a
    /// signature unless the user picked one.
    @Test("A new compose draft defaults to the automatic signature")
    func newDraftUsesTheAutomaticSignature() async throws {
        let api = FakeMailAPIClient()
        let outbox = await Self.outbox(api)

        let saved = try await outbox.saveDraft(ComposeDraft(
            mode: .new(mailboxID: "mbx_support"),
            fromAddress: "support@example.com",
            to: ["ada@example.net"],
            subject: "Hello",
            body: "Hi"
        ))

        #expect(saved.signature == .automatic)
        #expect(saved.signatureSnapshot?.id == "sig_mailbox")
        #expect(saved.signatureSnapshot?.text == "Support Team")
    }

    /// The switch has to reach the server, not just the window: sending consumes
    /// the DRAFT's snapshot when a `draftId` rides along (`resolveSendSignature`),
    /// so a selection that never got saved would not be the one that goes out.
    @Test("Switching signature is persisted on the draft and used by the send")
    func switchingSignatureReachesTheSentMessage() async throws {
        let api = FakeMailAPIClient()
        let outbox = await Self.outbox(api)
        var draft = try await outbox.saveDraft(ComposeDraft(
            mode: .new(mailboxID: "mbx_support"),
            fromAddress: "support@example.com",
            to: ["ada@example.net"],
            subject: "Hello",
            body: "Hi"
        ))

        draft.signature = .selected(id: "sig_personal")
        #expect(draft.isDirty, "changing the signature must schedule a save")
        draft = try await outbox.saveDraft(draft)
        #expect(draft.signatureSnapshot?.id == "sig_personal")

        _ = try await outbox.send(draft)
        #expect(await api.lastSentSignature.text == "Ada Lovelace")
    }

    /// "No signature" must survive a reopen. The stored snapshot is the only
    /// record of it, and a composer that rebuilt as `.automatic` would put the
    /// default back on the next autosave without the user touching anything.
    @Test("Reopening a draft keeps its stored choice, including No signature")
    func reopenedDraftKeepsItsChoice() async throws {
        let api = FakeMailAPIClient()
        let outbox = await Self.outbox(api)
        var draft = try await outbox.saveDraft(ComposeDraft(
            mode: .new(mailboxID: "mbx_support"),
            fromAddress: "support@example.com",
            to: ["ada@example.net"],
            subject: "Hello",
            body: "Hi"
        ))
        draft.signature = .noSignature
        draft = try await outbox.saveDraft(draft)
        let stored = try #require(await api.storedDraft(id: "drf_1"))

        let reopened = ComposePrefill.draft(stored)

        #expect(reopened.signature == .noSignature)
        #expect(reopened.isDirty == false, "reopening must not dirty the draft")
        let resaved = try await outbox.saveDraft(ComposeDraft(
            mode: reopened.mode,
            fromAddress: reopened.fromAddress,
            to: reopened.to,
            subject: reopened.subject,
            body: "Hi again",
            signature: reopened.signature,
            serverDraft: reopened.serverDraft
        ))
        #expect(resaved.signatureSnapshot?.mode == SignatureSnapshot.Mode.none)
    }

    /// The debounce race: the user switches signature and hits Send before the
    /// autosave fires. A `draftId` send uses the DRAFT's snapshot, so without a
    /// save first the message would go out with the previous signature.
    @Test("Sending inside the autosave debounce still uses the chosen signature")
    func sendFlushesAPendingSignatureSwitch() async throws {
        let api = FakeMailAPIClient()
        let outbox = await Self.outbox(api)
        var draft = try await outbox.saveDraft(ComposeDraft(
            mode: .new(mailboxID: "mbx_support"),
            fromAddress: "support@example.com",
            to: ["ada@example.net"],
            subject: "Hello",
            body: "Hi"
        ))
        #expect(draft.signatureSnapshot?.id == "sig_mailbox")

        // Switched but NOT saved — exactly where a send inside the debounce lands.
        draft.signature = .selected(id: "sig_personal")
        _ = try await outbox.send(draft)

        #expect(await api.lastSentSignature.id == "sig_personal")
    }

    /// A forward carries no `draftId`, so the selection in the body is the only
    /// thing that decides what the sent message gets.
    @Test("A forward's signature comes from the selection in the request")
    func forwardCarriesTheSelection() async throws {
        let api = FakeMailAPIClient()
        let outbox = await Self.outbox(api)
        var draft = ComposeDraft(
            mode: .forward(messageID: "msg_01"),
            fromAddress: "support@example.com",
            to: ["ada@example.net"],
            subject: "Fwd: Hello",
            body: "See below"
        )
        draft.signature = .selected(id: "sig_personal")

        _ = try await outbox.send(draft)

        #expect(await api.lastSentSignature.id == "sig_personal")
    }

    /// The snapshot describes the selection that was SENT. Adopting it after the
    /// user switched mid-flight would preview a signature the draft no longer
    /// asks for — and the mismatch has to keep the draft dirty so the next save
    /// fixes it.
    @Test("A signature switched during a save is not overwritten by the response")
    func switchDuringSaveSurvives() async throws {
        let api = FakeMailAPIClient()
        let outbox = await Self.outbox(api)
        let sent = ComposeDraft(
            mode: .new(mailboxID: "mbx_support"),
            fromAddress: "support@example.com",
            to: ["ada@example.net"],
            subject: "Hello",
            body: "Hi"
        )
        let saved = try await outbox.saveDraft(sent)

        var live = sent
        live.signature = .selected(id: "sig_personal")
        live.adoptServerState(from: saved, sent: sent)

        #expect(live.signature == .selected(id: "sig_personal"))
        #expect(live.signatureSnapshot == nil, "the automatic snapshot must not be adopted")
        #expect(live.isDirty, "the pending switch keeps the draft dirty")
    }

    /// Herald must never fold the signature into the body — the server appends
    /// it. This is the same invariant the quoted original has, and the one a
    /// preview-shaped feature is most likely to break.
    @Test("The authored body never contains the signature text")
    func bodyNeverCarriesTheSignature() async throws {
        let api = FakeMailAPIClient()
        let outbox = await Self.outbox(api)

        let saved = try await outbox.saveDraft(ComposeDraft(
            mode: .new(mailboxID: "mbx_support"),
            fromAddress: "support@example.com",
            to: ["ada@example.net"],
            subject: "Hello",
            body: "Hi"
        ))

        #expect(saved.body == "Hi")
        let stored = try #require(await api.storedDraft(id: "drf_1"))
        #expect(stored.content.text == "Hi")
        #expect(!stored.content.text.contains("Support Team"))
    }

    /// A server older than 1.3.4 answers 404. The composer must still work; the
    /// picker simply has nothing to show.
    @Test("A server without the signatures route surfaces as notFound")
    func missingRouteIsNotFound() async throws {
        let api = FakeMailAPIClient()
        await api.setSignatureFailure(.notFound)
        let outbox = OutboxService(api: api)

        await #expect(throws: OutboxError.self) {
            _ = try await outbox.signatures(from: "support@example.com")
        }
    }
}
