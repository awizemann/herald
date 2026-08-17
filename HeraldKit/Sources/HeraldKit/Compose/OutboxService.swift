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
    func send(_ draft: ComposeDraft) async throws(OutboxError) -> MessageSummary
}

extension OutboxService: Outboxing {}

/// Drafts, attachments and sending.
///
/// An actor because everything it does is off-main work (file reads, uploads)
/// and because a compose window must not race itself: two autosaves of the same
/// draft would otherwise both create a server draft.
public actor OutboxService {
    /// Per-attachment cap. The v1 spec declares no limit; the server rejects
    /// anything over 25 MiB (per file and per draft in total), so this is the
    /// client-side policy limit and is deliberately the smaller number.
    public static let defaultAttachmentByteLimit = 10 * 1024 * 1024

    private let api: any MailAPIClient
    private let attachmentByteLimit: Int

    /// Server-draft creations in flight, keyed by the compose window's local draft
    /// id. `POST /drafts` is the one non-idempotent call here: an autosave racing
    /// an `attach` (or two autosaves) on a draft with no server id yet would
    /// otherwise create two drafts and orphan one. Later callers join this task.
    private var pendingCreates: [ComposeDraft.ID: Task<Draft, any Error>] = [:]

    public init(api: any MailAPIClient, attachmentByteLimit: Int = OutboxService.defaultAttachmentByteLimit) {
        self.api = api
        self.attachmentByteLimit = attachmentByteLimit
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
    /// The size check happens before any read or request, so an oversized file
    /// costs neither memory nor a round trip.
    public func attach(_ fileURL: URL, to draft: ComposeDraft) async throws(OutboxError) -> ComposeDraft {
        let size = try Self.fileSize(of: fileURL)
        guard size <= attachmentByteLimit else {
            logger.warning("Rejected attachment of \(size) bytes (limit \(self.attachmentByteLimit))")
            throw OutboxError.attachmentTooLarge(bytes: size, limit: attachmentByteLimit)
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
        guard data.count <= attachmentByteLimit else {
            throw OutboxError.attachmentTooLarge(bytes: data.count, limit: attachmentByteLimit)
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

    // MARK: - Sending

    /// Sends the draft: `POST /reply` for a reply, `POST /send` otherwise.
    ///
    /// When the draft was persisted its id rides along as `draftId` so the server
    /// consumes it. On failure nothing is deleted — the server draft is still the
    /// user's text. On success the draft is deleted if it still exists.
    @discardableResult
    public func send(_ draft: ComposeDraft) async throws(OutboxError) -> MessageSummary {
        try validateAddresses(draft.allRecipients)

        let sent: MessageSummary
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
                draftID: draft.serverDraft?.id
            )
            sent = try await call { try await api.reply(input) }
        case .new, .forward:
            guard !draft.to.isEmpty else { throw OutboxError.noRecipients }
            let input = SendInput(
                from: draft.fromAddress,
                to: draft.to,
                cc: draft.cc,
                bcc: draft.bcc,
                subject: draft.subject,
                text: draft.body,
                attachmentIDs: draft.attachmentIDs,
                draftID: draft.serverDraft?.id
            )
            sent = try await call { try await api.send(input) }
        }

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
        return sent
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
