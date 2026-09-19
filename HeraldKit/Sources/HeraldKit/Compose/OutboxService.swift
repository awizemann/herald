import Foundation
import OSLog
import UniformTypeIdentifiers

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "Outbox")

/// Everything a compose window needs from the outbox.
///
/// `nonisolated` because ``OutboxService`` is an actor (and so are the test
/// fakes): an actor cannot conform to a global-actor-isolated protocol.
public nonisolated protocol Outboxing: Sendable {
    @discardableResult
    func saveDraft(_ draft: ComposeDraft) async throws(OutboxError) -> ComposeDraft
    func discard(_ draft: ComposeDraft) async throws(OutboxError)
    func attach(_ fileURL: URL, to draft: ComposeDraft) async throws(OutboxError) -> ComposeDraft
    func removeAttachment(_ attachmentID: String, from draft: ComposeDraft) async throws(OutboxError) -> ComposeDraft
    @discardableResult
    func send(_ draft: ComposeDraft) async throws(OutboxError) -> SendReceipt
    /// Signatures usable from `address`, for the compose picker.
    func signatures(from address: String) async throws(OutboxError) -> SignatureCandidates
}

/// What a successful send hands back: the message the server created, and the
/// draft with its send identity advanced.
///
/// The draft comes back because the send is where ``ComposeDraft/sendAttemptKey``
/// rotates: the caller has to adopt it, or a second message composed in the same
/// window would replay the key that just delivered and be deduped away.
///
/// `id` forwards to the message so a caller that only wanted the summary reads
/// the same as before.
public nonisolated struct SendReceipt: Sendable, Hashable, Identifiable {
    public let message: MessageSummary
    public let draft: ComposeDraft

    public init(message: MessageSummary, draft: ComposeDraft) {
        self.message = message
        self.draft = draft
    }

    public var id: String { message.id }
}

extension OutboxService: Outboxing {}

/// Drafts, attachments and sending.
///
/// An actor because everything it does is off-main work (file reads, uploads)
/// and because a compose window must not race itself: two autosaves of the same
/// draft would otherwise both create a server draft.
public actor OutboxService {
    private let api: any MailAPIClient
    /// Mirrors the server's caps (see ``AttachmentLimits/server``); injectable so
    /// tests can prove a boundary without writing 25 MiB to disk.
    private let limits: AttachmentLimits

    /// Server-draft creations in flight, keyed by the compose window's local draft
    /// id. `POST /drafts` is the one non-idempotent call here: an autosave racing
    /// an `attach` (or two autosaves) on a draft with no server id yet would
    /// otherwise create two drafts and orphan one. Later callers join this task.
    private var pendingCreates: [ComposeDraft.ID: Task<Draft, any Error>] = [:]

    /// Test seam: how many saves have JOINED someone else's in-flight create.
    /// It is what makes "the second save really did overlap the first" assertable
    /// instead of hoped-for — `async let` alone guarantees no interleaving.
    var joinedCreateCount = 0

    public init(api: any MailAPIClient, limits: AttachmentLimits = .server) {
        self.api = api
        self.limits = limits
    }

    // MARK: - Saving

    /// Creates the server draft on first save, updates it afterwards.
    ///
    /// The update carries the version stamp from the last server response. A 409
    /// means someone else saved in between: the draft is refetched once, our
    /// edits are re-stamped with the new version and retried exactly once. A
    /// second conflict surfaces as ``OutboxError/draftConflict`` — never a loop.
    @discardableResult
    public func saveDraft(_ draft: ComposeDraft) async throws(OutboxError) -> ComposeDraft {
        try validateAddresses(draft.allRecipients)
        var draft = draft

        guard let existing = draft.serverDraft else {
            let (created, joined) = try await createServerDraft(for: draft)
            draft.applySaved(created)
            guard joined else {
                logger.info("Created draft \(created.id, privacy: .public)")
                return draft
            }
            // We joined someone else's create, so the server holds THEIR content:
            // push ours on top of the identity they established.
            return try await update(draft, existing: created)
        }

        return try await update(draft, existing: existing)
    }

    /// The create half, deduplicated per compose window. The `Bool` says whether
    /// this caller joined an existing create rather than starting it.
    private func createServerDraft(for draft: ComposeDraft) async throws(OutboxError) -> (Draft, joined: Bool) {
        if let running = pendingCreates[draft.id] {
            joinedCreateCount += 1
            return (try await join(running), joined: true)
        }
        let input = draft.draftInput
        let api = self.api
        let task = Task<Draft, any Error> { try await api.createDraft(input) }
        pendingCreates[draft.id] = task
        defer { pendingCreates[draft.id] = nil }
        return (try await join(task), joined: false)
    }

    /// Awaits a shared create task with the same error mapping ``call(_:)`` gives.
    private func join(_ task: Task<Draft, any Error>) async throws(OutboxError) -> Draft {
        try await call { try await task.value }
    }

    private func update(
        _ draft: ComposeDraft,
        existing: Draft
    ) async throws(OutboxError) -> ComposeDraft {
        var draft = draft
        do {
            let updated = try await call { try await api.updateDraft(id: existing.id, with: draft.draftInput) }
            draft.applySaved(updated)
            return draft
        } catch .api(let error) where Self.isConflict(error) {
            logger.warning("Draft \(existing.id, privacy: .public) conflicted; refetching once")
            let latest = try await call { try await api.draft(id: existing.id) }
            draft.applySaved(latest)
            // Re-apply the user's edits on top of the server's version stamp.
            do {
                let updated = try await call { try await api.updateDraft(id: latest.id, with: draft.draftInput) }
                draft.applySaved(updated)
                return draft
            } catch .api(let retryError) where Self.isConflict(retryError) {
                logger.error("Draft \(existing.id, privacy: .public) conflicted again; giving up")
                throw OutboxError.draftConflict
            }
        }
    }

    /// Deletes the server draft, if any. Idempotent: a 404 means it is already gone.
    public func discard(_ draft: ComposeDraft) async throws(OutboxError) {
        guard let id = draft.serverDraft?.id else { return }
        try await deleteDraft(id: id)
    }

    // MARK: - Attachments

    /// Uploads a local file to the draft, autosaving first when there is no
    /// server draft to attach to (`POST /drafts/{id}/attachments` needs an id).
    ///
    /// Every limit is checked before any read or request, so a file the server
    /// would 413 costs neither memory nor a round trip.
    public func attach(_ fileURL: URL, to draft: ComposeDraft) async throws(OutboxError) -> ComposeDraft {
        let size = try Self.fileSize(of: fileURL)
        if let rejection = limits.rejection(forAdding: size, to: draft.uploadedAttachments) {
            logger.warning("Rejected attachment: \(rejection.logCode, privacy: .public)")
            throw rejection
        }

        var draft = draft
        if draft.serverDraft == nil {
            draft = try await saveDraft(draft)
        }
        guard let draftID = draft.serverDraft?.id else { throw OutboxError.draftConflict }

        // Reading here is safe: the actor is never the main actor.
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            logger.error("Attachment unreadable: \(error.localizedDescription, privacy: .private)")
            throw OutboxError.fileUnreadable(fileURL)
        }
        // Re-checked against what we actually read and against the attachment
        // list the autosave above may have refreshed from the server: the first
        // check used a stat and a possibly stale draft, and neither is a promise.
        if let rejection = limits.rejection(forAdding: data.count, to: draft.uploadedAttachments) {
            logger.warning("Rejected attachment after read: \(rejection.logCode, privacy: .public)")
            throw rejection
        }

        let filename = Self.sanitizedFilename(fileURL.lastPathComponent)
        let uploaded = try await call {
            try await api.addDraftAttachment(
                draftID: draftID,
                filename: filename,
                mimeType: Self.mimeType(for: fileURL),
                data: data
            )
        }
        draft.applyUpload(uploaded, from: fileURL)
        logger.info("Attached \(uploaded.id, privacy: .public) (\(uploaded.sizeBytes) bytes) to \(draftID, privacy: .public)")
        return draft
    }

    /// Removes an uploaded attachment. A 404 is success — it is already gone.
    public func removeAttachment(
        _ attachmentID: String,
        from draft: ComposeDraft
    ) async throws(OutboxError) -> ComposeDraft {
        var draft = draft
        guard let draftID = draft.serverDraft?.id else {
            draft.applyRemoval(attachmentID: attachmentID)
            return draft
        }
        do {
            try await call { try await api.removeDraftAttachment(draftID: draftID, attachmentID: attachmentID) }
        } catch .api(.notFound) {
            logger.warning("Attachment \(attachmentID, privacy: .public) already removed")
        }
        draft.applyRemoval(attachmentID: attachmentID)
        return draft
    }

    // MARK: - Signatures

    /// The candidate list for one sending address. A server older than upstream
    /// 1.3.4 has no such route and answers 404 — the caller treats that as "this
    /// server has no signatures" and hides the picker.
    public func signatures(from address: String) async throws(OutboxError) -> SignatureCandidates {
        try await call { try await api.signatures(from: address) }
    }

    // MARK: - Sending

    /// Sends the draft: `POST /reply` for a reply, `POST /forward` for a forward,
    /// `POST /send` otherwise.
    ///
    /// Forwards used to go through `POST /send`, whose `SendInput` has NO forward
    /// link — the only carrier was `draftId`, so a forward sent before the first
    /// autosave had persisted a server draft arrived as the user's own text with
    /// the forwarded message silently missing. `POST /forward` (upstream 1.3.4)
    /// names the message being forwarded in the request itself, so the content
    /// cannot be lost. Herald therefore REQUIRES a server at 1.3.4 or newer to
    /// forward; an older one answers 404 and the compose window keeps the draft.
    ///
    /// `POST /forward` has no `draftId`, so the draft is not consumed server-side
    /// — its uploaded attachments ride along as `attachmentIds` and the draft is
    /// deleted here afterwards, as on the other two paths. One difference: the
    /// server copies a draft's LABELS onto the sent message only when it was
    /// given a `draftId` (send/service.ts), so labels a forward draft carried are
    /// not inherited. Herald does not surface draft labels yet, so nothing is
    /// visibly lost; revisit when labels land.
    ///
    /// The signature selection rides along on all three routes, but only decides
    /// on the two that carry no `draftId` (a forward, or a send/reply before the
    /// first autosave): with a `draftId` the server uses the snapshot it stored
    /// for that draft and ignores the body's selection (`resolveSendSignature`).
    /// The selection is saved onto the draft as it is made, so the two agree.
    ///
    /// When the draft was persisted its id rides along as `draftId` so the server
    /// consumes it. On failure nothing is deleted — the server draft is still the
    /// user's text. On success the draft is deleted if it still exists.
    ///
    /// ## Retry identity (upstream 1.4.0)
    /// Every route carries ``ComposeDraft/sendAttemptKey`` as `idempotencyKey`,
    /// so a retry after a timeout replays the stored 201 instead of delivering a
    /// second copy. It matters most on `POST /forward`, which has no `draftId`
    /// and so no other identity at all; a server older than 1.4.0 strips the
    /// unknown field, which is exactly the behaviour Herald had before.
    ///
    /// `SEND_KEY_CONFLICT` (the same key with a body the server hashes
    /// differently) rotates the key and retries EXACTLY once — never a loop. The
    /// rotation is local to this call: if the retry fails too, the caller's draft
    /// keeps the old key, its next attempt 409s once more and rotates again. That
    /// costs a round trip but can never invent a fresh identity for a message the
    /// server may already hold.
    ///
    /// The two 503s become ``OutboxError/sendOnHold(_:)`` and are NOT retried
    /// here, automatically or otherwise: one of them means the mail is already
    /// accepted.
    @discardableResult
    public func send(_ draft: ComposeDraft) async throws(OutboxError) -> SendReceipt {
        try validateAddresses(draft.allRecipients)
        var draft = draft
        // A send that names a draft uses the SNAPSHOT stored on that draft and
        // ignores the selection in the body. Switching signature and hitting Send
        // inside the autosave debounce would otherwise send the previous
        // signature — so a disagreement is resolved before the send, not after.
        //
        // Only for the routes that carry a `draftId`: `POST /forward` does not,
        // so its body's selection is already the one that decides and an extra
        // PATCH would be a round trip for nothing.
        let sendsDraftID = draft.mode.forwardOfMessageID == nil
        if sendsDraftID,
           let existing = draft.serverDraft,
           SignatureSelection(existing.signature) != draft.signature {
            logger.info("Saving draft \(existing.id, privacy: .public) so the send uses the chosen signature")
            draft = try await saveDraft(draft)
        }

        let sent = try await postSend(draft)
        draft.rotateSendAttemptKey()

        if let draftID = draft.serverDraft?.id {
            // Best effort: the send already succeeded, so a stale draft is a
            // cosmetic problem and must not turn into a send failure.
            do {
                try await deleteDraft(id: draftID)
            } catch {
                logger.warning("Sent, but draft \(draftID, privacy: .public) could not be deleted")
            }
        }
        logger.info("Sent message \(sent.id, privacy: .public)")
        return SendReceipt(message: sent, draft: draft)
    }

    /// The POST itself, with the idempotency rules around it.
    ///
    /// `key` overrides the draft's own — that is how the single `SEND_KEY_CONFLICT`
    /// retry re-posts under a rotated identity without mutating anything the
    /// caller can see.
    private func postSend(_ draft: ComposeDraft, key: String? = nil) async throws(OutboxError) -> MessageSummary {
        do {
            return try await postOnce(draft, key: key ?? draft.sendAttemptKey)
        } catch {
            // Matched on the server's CODE, never the status: the middleware maps
            // every non-401/403/404 to `.server`, so 409 alone would also catch
            // `DRAFT_CONFLICT`, and 503 a plain outage.
            guard case .api(.server(let code, _)) = error else { throw error }
            if let hold = SendHold.code(code) {
                // Deliberately not retried, here or upstairs:
                // `SEND_RECOVERY_UNAVAILABLE` means the mail is already accepted,
                // and a second POST is the one thing the server asks the client
                // not to do.
                logger.error("Send held by the server: \(hold.rawValue, privacy: .public)")
                throw OutboxError.sendOnHold(hold)
            }
            // The key is spoken for by a DIFFERENT body — the user edited after a
            // failed attempt. Only the first attempt may rotate: a non-nil `key`
            // means this IS the retry, so the conflict surfaces instead.
            guard Self.isKeyConflict(code), key == nil else { throw error }
            logger.warning("Send key conflicted; rotating the key and retrying once")
            return try await postSend(draft, key: UUID().uuidString)
        }
    }

    /// One attempt, on whichever route the draft's mode names.
    private func postOnce(
        _ draft: ComposeDraft,
        key idempotencyKey: String
    ) async throws(OutboxError) -> MessageSummary {
        switch draft.mode {
        case .reply(let messageID, _):
            // Recipients may be empty for a reply: the server falls back to the
            // original message's reply targets.
            let input = ReplyInput(
                messageID: messageID,
                from: draft.fromAddress,
                to: draft.to.isEmpty ? nil : draft.to,
                cc: draft.cc.isEmpty ? nil : draft.cc,
                bcc: draft.bcc.isEmpty ? nil : draft.bcc,
                text: draft.body,
                attachmentIDs: draft.attachmentIDs,
                draftID: draft.serverDraft?.id,
                signature: draft.signature,
                idempotencyKey: idempotencyKey
            )
            return try await call { try await api.reply(input) }
        case .forward(let messageID):
            guard !draft.to.isEmpty else { throw OutboxError.noRecipients }
            let input = ForwardInput(
                messageID: messageID,
                from: draft.fromAddress,
                to: draft.to,
                cc: draft.cc,
                bcc: draft.bcc,
                // The server derives `Fwd: …` when the subject is omitted, and
                // its schema is `z.string().trim().min(1)` — so a whitespace-only
                // subject must be omitted too, not sent and 400'd.
                subject: Self.trimmedOrNil(draft.subject),
                text: draft.body,
                attachmentIDs: draft.attachmentIDs,
                signature: draft.signature,
                idempotencyKey: idempotencyKey
            )
            return try await call { try await api.forward(input) }
        case .new:
            guard !draft.to.isEmpty else { throw OutboxError.noRecipients }
            let input = SendInput(
                from: draft.fromAddress,
                to: draft.to,
                cc: draft.cc,
                bcc: draft.bcc,
                subject: draft.subject,
                text: draft.body,
                attachmentIDs: draft.attachmentIDs,
                draftID: draft.serverDraft?.id,
                signature: draft.signature,
                idempotencyKey: idempotencyKey
            )
            return try await call { try await api.send(input) }
        }
    }


    // MARK: - Helpers

    private func deleteDraft(id: String) async throws(OutboxError) {
        do {
            try await call { try await api.deleteDraft(id: id) }
        } catch .api(.notFound) {
            logger.warning("Draft \(id, privacy: .public) already deleted")
        }
    }

    private func validateAddresses(_ addresses: [String]) throws(OutboxError) {
        for address in addresses where !EmailAddress.isValid(address) {
            // The address itself is never logged — only that one was rejected.
            logger.warning("Rejected an invalid recipient address")
            throw OutboxError.invalidRecipient(address)
        }
    }

    /// Wraps every API call so a ``MailAPIError`` becomes ``OutboxError/api(_:)``
    /// and each failure is logged exactly once, at the boundary.
    private func call<T>(_ body: () async throws -> T) async throws(OutboxError) -> T {
        do {
            return try await body()
        } catch let error as MailAPIError {
            logger.warning("Outbox API call failed: \(error.logCode, privacy: .public)")
            throw OutboxError.api(error)
        } catch {
            logger.error("Outbox API call failed unexpectedly: \(error.localizedDescription, privacy: .private)")
            throw OutboxError.api(.transport(.init(error)))
        }
    }

    /// 409 from `PATCH /drafts/{id}` arrives as `.server` — the middleware maps
    /// every non-401/403/404 status that way. Upstream's code is `DRAFT_CONFLICT`.
    nonisolated static func isConflict(_ error: MailAPIError) -> Bool {
        guard case .server(let code, _) = error else { return false }
        return code.caseInsensitiveCompare("DRAFT_CONFLICT") == .orderedSame || code == "http_409"
    }

    /// Upstream answers 409 `SEND_KEY_CONFLICT` when an idempotency key is reused
    /// with a body it hashes differently. Matched on the CODE, not the status:
    /// the middleware maps every non-401/403/404 to `.server`, so 409 alone would
    /// also catch `DRAFT_CONFLICT`.
    nonisolated static func isKeyConflict(_ code: String) -> Bool {
        code.caseInsensitiveCompare("SEND_KEY_CONFLICT") == .orderedSame
    }

    /// `nil` for a string the server's `z.string().trim().min(1)` would reject.
    nonisolated static func trimmedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func fileSize(of url: URL) throws(OutboxError) -> Int {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize else { throw OutboxError.fileUnreadable(url) }
            return size
        } catch {
            logger.warning("Could not stat attachment: \(error.localizedDescription, privacy: .private)")
            throw OutboxError.fileUnreadable(url)
        }
    }

    /// Strips path separators and control characters so a hostile filename cannot
    /// escape the server's storage key or the user's Downloads folder.
    nonisolated static func sanitizedFilename(_ filename: String) -> String {
        let cleaned = filename.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == "\\" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar) {
                return "_"
            }
            return Character(scalar)
        }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespaces)
        // Leading dots too: they make hidden files and are how "../" survives.
        let name = String(trimmed.drop(while: { $0 == "." }))
        return name.isEmpty ? "attachment" : String(name.prefix(255))
    }

    nonisolated static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}
