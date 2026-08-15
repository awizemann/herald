import Foundation
import Testing
@testable import HeraldKit

/// Every test here asserts the *sequence* of API calls, not just the outcome:
/// the failure modes that matter (double-create, missing version stamp, retry
/// loops, uploading before the size check) are all visible only in the call log.
@Suite struct OutboxServiceTests {
    static func draft(
        mode: ComposeMode = .new(mailboxID: "mbx_support"),
        to: [String] = ["ada@example.net"],
        subject: String = "Hello",
        body: String = "Hi there"
    ) -> ComposeDraft {
        ComposeDraft(
            mode: mode,
            fromAddress: "support@example.com",
            to: to,
            subject: subject,
            body: body
        )
    }

    static func temporaryFile(named name: String, bytes: Int) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("outbox-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    // MARK: - Saving

    /// Fails if the second save POSTs a new draft again (duplicate drafts on the
    /// server) or PATCHes without the version stamp (the server would 409).
    @Test("First save creates, second save updates with the version stamp")
    func createThenUpdate() async throws {
        let api = FakeMailAPIClient()
        let outbox = OutboxService(api: api)

        var draft = try await outbox.saveDraft(Self.draft())
        #expect(draft.serverDraft?.id == "drf_1")
        #expect(draft.serverDraft?.version == 1)
        #expect(draft.isDirty == false)

        draft.subject = "Hello again"
        #expect(draft.isDirty)
        draft = try await outbox.saveDraft(draft)
        #expect(draft.serverDraft?.version == 2)

        let calls = await api.calls
        #expect(calls.count == 2)
        #expect(calls.count { if case .createDraft = $0 { true } else { false } } == 1)
        #expect(calls.last == .updateDraft(id: "drf_1", version: 1))
        let stored = await api.storedDraft(id: "drf_1")
        #expect(stored?.content.subject == "Hello again")
    }

    /// Fails on "no retry" (a lost edit surfaced as an error the user cannot fix)
    /// and on a retry loop: exactly one refetch + one retry are expected.
    @Test("A 409 refetches once and retries once, then succeeds")
    func conflictRefetchesAndRetries() async throws {
        let api = FakeMailAPIClient()
        let outbox = OutboxService(api: api)
        var draft = try await outbox.saveDraft(Self.draft())

        // Another session saved: our stamp is now stale.
        await api.bumpStoredDraftVersion(id: "drf_1")
        draft.subject = "Edited here"
        draft = try await outbox.saveDraft(draft)

        #expect(draft.serverDraft?.version == 3)
        let calls = await api.calls
        #expect(calls == [
            calls[0],
            .updateDraft(id: "drf_1", version: 1),
            .fetchDraft("drf_1"),
            .updateDraft(id: "drf_1", version: 2),
        ])
        let stored = await api.storedDraft(id: "drf_1")
        #expect(stored?.content.subject == "Edited here")
    }

    /// Fails if a persistent conflict loops forever or leaks the raw
    /// `.server(code:)` error the UI cannot act on.
    @Test("A second conflict surfaces as .draftConflict without further retries")
    func conflictGivesUpAfterOneRetry() async throws {
        let api = FakeMailAPIClient()
        let outbox = OutboxService(api: api)
        var draft = try await outbox.saveDraft(Self.draft())
        await api.setForcedConflicts(2)

        draft.subject = "Edited"
        await #expect(throws: OutboxError.draftConflict) {
            try await outbox.saveDraft(draft)
        }
        let updates = await api.calls.count { if case .updateDraft = $0 { true } else { false } }
        let fetches = await api.calls.count { if case .fetchDraft = $0 { true } else { false } }
        #expect(updates == 2)
        #expect(fetches == 1)
    }

    /// Fails if a malformed address is only caught by the server (round trip
    /// wasted, error message unhelpful).
    @Test("Invalid recipients are rejected before any request")
    func invalidRecipientIsLocal() async throws {
        let api = FakeMailAPIClient()
        let outbox = OutboxService(api: api)
        await #expect(throws: OutboxError.invalidRecipient("not-an-address")) {
            try await outbox.saveDraft(Self.draft(to: ["ada@example.net", "not-an-address"]))
        }
        #expect(await api.calls.isEmpty)
    }

    // MARK: - Attachments

    /// Fails if the size check happens after the upload starts (or after the
    /// whole file is read into memory) — the zero-call assertion is the point.
    @Test("An oversized attachment is rejected before any network call")
    func oversizedAttachmentMakesNoRequest() async throws {
        let api = FakeMailAPIClient()
        let outbox = OutboxService(api: api, attachmentByteLimit: 1_024)
        let url = try Self.temporaryFile(named: "big.bin", bytes: 4_096)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        await #expect(throws: OutboxError.attachmentTooLarge(bytes: 4_096, limit: 1_024)) {
            try await outbox.attach(url, to: Self.draft())
        }
        #expect(await api.calls.isEmpty)
    }

    /// Fails if the upload is attempted without a draft id (the route needs one):
    /// the create must come first, in that order.
    @Test("Attaching to an unsaved draft autosaves first, then uploads")
    func attachAutosavesFirst() async throws {
        let api = FakeMailAPIClient()
        let outbox = OutboxService(api: api)
        let url = try Self.temporaryFile(named: "notes.txt", bytes: 12)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let draft = try await outbox.attach(url, to: Self.draft())
        let calls = await api.calls
        #expect(calls.count == 2)
        if case .createDraft = calls[0] {} else { Issue.record("expected create first, got \(calls[0])") }
        #expect(calls[1] == .addAttachment(draftID: "drf_1", filename: "notes.txt", bytes: 12))
        #expect(draft.uploadedAttachments.map(\.id) == ["att_1"])
        #expect(draft.uploadedAttachments.first?.contentType == "text/plain")
    }

    /// Fails on a filename that keeps path separators — a server-side key or a
    /// later save panel would then escape its directory.
    @Test("Attachment filenames are sanitized before upload")
    func filenameIsSanitized() {
        #expect(OutboxService.sanitizedFilename("../../etc/passwd") == "_.._etc_passwd")
        #expect(OutboxService.sanitizedFilename(".ssh") == "ssh")
        #expect(OutboxService.sanitizedFilename("a\u{0}b.txt") == "a_b.txt")
        #expect(OutboxService.sanitizedFilename("   ") == "attachment")
    }

    /// Fails if removal is not idempotent — a double click would surface a 404
    /// the user can do nothing about.
    @Test("Removing an already-removed attachment succeeds")
    func removeAttachmentTolerates404() async throws {
        let api = FakeMailAPIClient()
        let outbox = OutboxService(api: api)
        let url = try Self.temporaryFile(named: "notes.txt", bytes: 12)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var draft = try await outbox.attach(url, to: Self.draft())
        draft = try await outbox.removeAttachment("att_1", from: draft)
        #expect(draft.uploadedAttachments.isEmpty)
        // Second removal: the server no longer knows the attachment.
        draft.applyUpload(DraftAttachment(id: "att_1", filename: "notes.txt", contentType: "text/plain", sizeBytes: 12), from: nil)
        draft = try await outbox.removeAttachment("att_1", from: draft)
        #expect(draft.uploadedAttachments.isEmpty)
    }

    // MARK: - Sending

    /// Fails if replies go to `POST /send` (the server would not thread them) or
    /// carry the wrong message id.
    @Test("send(.reply) posts to reply with the original message id and draft id")
    func replyUsesReplyRoute() async throws {
        let api = FakeMailAPIClient()
        let outbox = OutboxService(api: api)
        var draft = Self.draft(mode: .reply(toMessageID: "msg_01", replyAll: false))
        draft = try await outbox.saveDraft(draft)

        let sent = try await outbox.send(draft)
        #expect(sent.id == "msg_reply")

        let calls = await api.calls
        #expect(calls.contains { if case .sendMessage = $0 { true } else { false } } == false)
        guard let replyCall = calls.compactMap({ call -> ReplyInput? in
            if case .replyToMessage(let input) = call { return input }
            return nil
        }).first else {
            Issue.record("no reply call recorded")
            return
        }
        #expect(replyCall.messageID == "msg_01")
        #expect(replyCall.draftID == "drf_1")
        #expect(replyCall.to == ["ada@example.net"])
    }

    /// Fails if the draft is not consumed after a successful send — the user
    /// would find a ghost copy in Drafts.
    @Test("A successful send deletes the server draft")
    func successDeletesDraft() async throws {
        let api = FakeMailAPIClient()
        let outbox = OutboxService(api: api)
        let draft = try await outbox.saveDraft(Self.draft())
        _ = try await outbox.send(draft)

        #expect(await api.calls.contains(.deleteDraft("drf_1")))
        #expect(await api.storedDraftCount() == 0)
    }

    /// The one that matters most: a failed send must lose nothing. Fails on any
    /// implementation that deletes the draft before (or regardless of) success.
    @Test("A failed send preserves the server draft and surfaces a typed error")
    func failedSendPreservesDraft() async throws {
        let api = FakeMailAPIClient()
        let outbox = OutboxService(api: api)
        let draft = try await outbox.saveDraft(Self.draft())
        await api.setSendFailure(.transport(.init(URLError(.notConnectedToInternet))))

        await #expect(throws: OutboxError.self) { try await outbox.send(draft) }

        #expect(await api.calls.contains { if case .deleteDraft = $0 { true } else { false } } == false)
        #expect(await api.storedDraft(id: "drf_1")?.content.subject == "Hello")
    }

    /// Fails if an empty `to` reaches the server as a 400 instead of being caught
    /// where the compose window can point at the field.
    @Test("Sending a new message with no recipients fails locally")
    func sendWithoutRecipients() async throws {
        let api = FakeMailAPIClient()
        let outbox = OutboxService(api: api)
        await #expect(throws: OutboxError.noRecipients) {
            try await outbox.send(Self.draft(to: []))
        }
        #expect(await api.calls.isEmpty)
    }

    /// Fails if discard treats "already deleted" as an error, which would block
    /// closing a compose window whose draft was removed elsewhere.
    @Test("Discard tolerates a 404 and is a no-op for unsaved drafts")
    func discardIsIdempotent() async throws {
        let api = FakeMailAPIClient()
        let outbox = OutboxService(api: api)
        let draft = try await outbox.saveDraft(Self.draft())

        try await outbox.discard(draft)
        try await outbox.discard(draft) // draft is already gone: 404
        try await outbox.discard(Self.draft()) // never saved: no request

        let deletes = await api.calls.count { if case .deleteDraft = $0 { true } else { false } }
        #expect(deletes == 2)
    }
}
