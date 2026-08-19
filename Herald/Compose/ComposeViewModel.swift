import AppKit
import Foundation
import HeraldKit
import OSLog

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "Compose")

/// One compose window's state: the draft, the text the user is typing into the
/// address fields, autosave and the send/discard verbs.
///
/// The heavy work (drafts, uploads, sending) all lives behind ``Outboxing`` —
/// an actor in production — so nothing here blocks the main actor beyond the
/// first suspension point.
@MainActor
@Observable
final class ComposeViewModel {
    enum Status: Equatable {
        case idle
        case saving
        case sending
        case failed(String)

        var message: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    /// Which address field an error belongs to, so the hint sits under it.
    enum Field: Hashable { case to, cc, bcc }

    // MARK: Editable state

    var toText: String { didSet { commitRecipients(); edited(oldValue != toText) } }
    var ccText: String { didSet { commitRecipients(); edited(oldValue != ccText) } }
    var bccText: String { didSet { commitRecipients(); edited(oldValue != bccText) } }
    var subject: String {
        didSet {
            draft.subject = subject
            edited(oldValue != subject)
        }
    }
    var bodyText: String {
        didSet {
            draft.body = bodyText
            edited(oldValue != bodyText)
        }
    }

    // MARK: Derived / published state

    private(set) var draft: ComposeDraft
    private(set) var status: Status = .idle {
        didSet {
            guard status != oldValue, let message = status.message else { return }
            announcement = message
        }
    }

    /// Addresses that failed ``EmailAddress/isValid(_:)``, per field.
    private(set) var invalidAddresses: [Field: [String]] = [:]
    /// The message the error bar shows, announced when it appears. VoiceOver has
    /// no reason to visit the bottom of a compose window, so an error that is
    /// only drawn there is an error a blind user never learns about.
    private(set) var announcement: String?
    /// Set when the window should go away: send succeeded, or the user discarded.
    private(set) var isClosed = false
    /// Drives the ⌘W confirmation sheet.
    var confirmsClose = false

    private let outbox: any Outboxing
    private let autosaveDelay: Duration
    /// The draft as opened: what "the user has typed something" is measured against.
    private let initialDraft: ComposeDraft
    /// Where this window reports what it did to its server draft, so the Drafts
    /// folder reflects an autosave immediately instead of at the next poll.
    /// `@MainActor` because the view-model that consumes it is.
    private let draftCache: @MainActor @Sendable (DraftCacheEvent) -> Void
    /// Usage analytics, same seam as ``MailViewModel/record``: a closure, so a
    /// composer can neither flush nor read the opt-out. Default no-op.
    @ObservationIgnored private let record: @MainActor @Sendable (UsageEvent) -> Void
    /// Exposed so tests can await the debounce instead of sleeping on a wall clock.
    @ObservationIgnored private(set) var autosaveTask: Task<Void, Never>?

    init(
        context: ComposeContext,
        outbox: any Outboxing,
        autosaveDelay: Duration = .seconds(2),
        record: @escaping @MainActor @Sendable (UsageEvent) -> Void = { _ in },
        draftCache: @escaping @MainActor @Sendable (DraftCacheEvent) -> Void = { _ in }
    ) {
        let draft = context.makeDraft()
        self.draft = draft
        self.initialDraft = draft
        self.outbox = outbox
        self.record = record
        self.autosaveDelay = autosaveDelay
        self.draftCache = draftCache
        self.toText = draft.to.joined(separator: ", ")
        self.ccText = draft.cc.joined(separator: ", ")
        self.bccText = draft.bcc.joined(separator: ", ")
        self.subject = draft.subject
        self.bodyText = draft.body
        // Reopening an existing draft takes ownership of it straight away: the
        // fence this raises is what stops a poll that is already in flight from
        // writing a pre-edit listing over the row under the user.
        if let existing = draft.serverDraft { draftCache(.saved(existing)) }
    }

    /// Reports the server's latest word on this draft to the Drafts folder.
    private func publishDraftState() {
        guard let saved = draft.serverDraft else { return }
        draftCache(.saved(saved))
    }

    // MARK: - Presentation

    var windowTitle: String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Message" : trimmed
    }

    var attachments: [DraftAttachment] { draft.uploadedAttachments }

    /// Busy includes queued uploads: a batch that finishes its first file resets
    /// `status` to idle, and a Send button that re-enables there would send the
    /// message without the files still on their way up.
    var isBusy: Bool { status == .saving || status == .sending || !pendingUploads.isEmpty }

    /// Whether closing would lose work the server has not seen.
    var hasUnsavedChanges: Bool {
        // A sent or discarded composer owns nothing anymore: the programmatic
        // dismissal that follows `send()` still passes through windowShouldClose,
        // and must never turn into a "save or discard?" sheet (real-run finding).
        guard !isClosed, draft.isDirty else { return false }
        return draft.to != initialDraft.to
            || draft.cc != initialDraft.cc
            || draft.bcc != initialDraft.bcc
            || draft.subject != initialDraft.subject
            || draft.body != initialDraft.body
            || !draft.pendingAttachments.isEmpty
            || !pendingUploads.isEmpty
    }

    func invalid(_ field: Field) -> [String] { invalidAddresses[field] ?? [] }

    func hint(for field: Field) -> String? {
        let bad = invalid(field)
        guard !bad.isEmpty else { return nil }
        return bad.count == 1
            ? "“\(bad[0])” is not a valid email address."
            : "\(bad.count) addresses are not valid email addresses."
    }

    // MARK: - Recipients

    /// Splits on commas, semicolons and whitespace so paste-from-anywhere works.
    nonisolated static func parseAddresses(_ text: String) -> [String] {
        let parts = text.split { $0 == "," || $0 == ";" || $0.isWhitespace }
        return EmailAddress.dedupe(parts.map(String.init))
    }

    private func commitRecipients() {
        draft.to = Self.parseAddresses(toText)
        draft.cc = Self.parseAddresses(ccText)
        draft.bcc = Self.parseAddresses(bccText)
        invalidAddresses = [
            .to: draft.to.filter { !EmailAddress.isValid($0) },
            .cc: draft.cc.filter { !EmailAddress.isValid($0) },
            .bcc: draft.bcc.filter { !EmailAddress.isValid($0) },
        ].filter { !$0.value.isEmpty }
    }

    private var hasInvalidAddresses: Bool { !invalidAddresses.isEmpty }

    // MARK: - Autosave

    private func edited(_ changed: Bool) {
        guard changed else { return }
        if status.message != nil { status = .idle }
        scheduleAutosave()
    }

    /// Debounced: every edit cancels the pending save, so a burst of typing
    /// costs one round trip rather than one per keystroke.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [autosaveDelay] in
            do {
                try await Task.sleep(for: autosaveDelay)
            } catch {
                return // Superseded by a later edit, or the window closed.
            }
            guard !Task.isCancelled else { return }
            await self.saveNow()
        }
    }

    /// Persists the draft if there is anything to persist. Never throws: an
    /// autosave failure is surfaced inline and the text stays in the window.
    func saveNow() async {
        guard !isClosed, draft.isDirty, !hasInvalidAddresses else { return }
        guard !draft.to.isEmpty || !draft.subject.isEmpty || !draft.body.isEmpty else { return }
        status = .saving
        // The snapshot that goes to the server; the response is MERGED into
        // whatever the user has typed since, never assigned over it. Assigning
        // the response back reverted every keystroke made during the round trip,
        // and a server that normalises anything (trims a subject, rewrites the
        // body) left the draft dirty again — an autosave loop.
        let sent = draft
        do {
            let saved = try await outbox.saveDraft(sent)
            draft.adoptServerState(from: saved, sent: sent)
            // The cache learns about the draft the moment the server does, so the
            // Drafts folder shows what is being typed without waiting for a poll.
            publishDraftState()
            record(.draftSaved)
            if status == .saving { status = .idle }
        } catch {
            logger.warning("Draft autosave failed: \(error.logCode, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }

    /// Saves a pending edit and then stops the timer, for the window actually
    /// going away.
    ///
    /// `stop()` alone cancels the debounce, so closing the window inside the
    /// autosave delay — which is most closes, since the last thing the user does
    /// is type — threw away everything typed since the previous save.
    func flushAndStop() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        // Whatever else happens, the window is going away: the poll must get its
        // draft back or it could never tombstone that row again.
        defer { if let id = draft.serverDraft?.id { draftCache(.closed(id)) } }
        guard !isClosed, draft.isDirty else { return }
        await saveNow()
    }

    /// Test seam and window-close hook: waits for a pending debounce to finish.
    func waitForAutosave() async {
        await autosaveTask?.value
    }

    // MARK: - Send / discard

    /// Validates locally first, so an obviously bad address never costs a round
    /// trip and the error lands on the field instead of in an alert.
    @discardableResult
    func send() async -> Bool {
        autosaveTask?.cancel()
        // ⌘⇧D can beat a queued upload to the punch; the attachment ids only exist
        // once the uploads have landed.
        await waitForUploads()
        commitRecipients()
        guard !hasInvalidAddresses else {
            status = .failed(hint(for: .to) ?? hint(for: .cc) ?? hint(for: .bcc) ?? "Check the recipients.")
            // The local checks are the same failures the server would report, so
            // they are reported the same way — the kind only, never the address.
            record(.sendFailed(kind: .invalidRecipient))
            return false
        }
        if draft.allRecipients.isEmpty, draft.mode.replyToMessageID == nil {
            status = .failed(OutboxError.noRecipients.localizedDescription)
            record(.sendFailed(kind: .noRecipients))
            return false
        }
        status = .sending
        // Captured BEFORE the send: sending CONSUMES the server draft (the
        // outbox deletes it afterwards), so this is the last moment its id is
        // knowable — and the Drafts folder has to drop the row now rather than
        // show a draft that no longer exists until the next poll.
        let serverDraftID = draft.serverDraft?.id
        do {
            _ = try await outbox.send(draft)
            isClosed = true
            // Counts and two booleans only — never an address, a subject or a
            // file name.
            record(.messageSent(
                attachments: UsageBucket(count: draft.uploadedAttachments.count),
                hasCC: !draft.cc.isEmpty,
                hasBCC: !draft.bcc.isEmpty
            ))
            if let serverDraftID { draftCache(.removed(serverDraftID)) }
            return true
        } catch {
            // Nothing is discarded: the window stays open with everything in it.
            logger.warning("Send failed: \(error.logCode, privacy: .public)")
            // `send` throws a typed `OutboxError`, so there is nothing to unwrap
            // — and the kind is all that is kept.
            record(.sendFailed(kind: UsageOutboxErrorKind(error)))
            status = .failed(error.localizedDescription)
            return false
        }
    }

    func discard() async {
        autosaveTask?.cancel()
        cancelAllUploads()
        isClosed = true
        record(.composeDiscarded)
        let serverDraftID = draft.serverDraft?.id
        do {
            try await outbox.discard(draft)
        } catch {
            logger.warning("Discarding the draft failed: \(error.logCode, privacy: .public)")
        }
        // Unconditional: `discard` is 404-tolerant, so "the delete threw" does not
        // mean the draft survived — and a row left behind for a draft the user
        // explicitly threw away is worse than one extra poll's correction.
        if let serverDraftID { draftCache(.removed(serverDraftID)) }
    }

    /// ⌘W: close outright, or ask first when there is unsaved work.
    func requestClose() {
        if hasUnsavedChanges {
            confirmsClose = true
        } else {
            close()
        }
    }

    /// Closes without deleting the server draft — "Save" in the close sheet.
    func saveAndClose() async {
        autosaveTask?.cancel()
        await waitForUploads()
        await saveNow()
        guard status.message == nil else { return } // Save failed: keep the window.
        isClosed = true
    }

    func close() {
        autosaveTask?.cancel()
        isClosed = true
    }

    /// Called from the window when it actually goes away, so no timer — and no
    /// upload waiting on a window that no longer exists — outlives it.
    func stop() {
        autosaveTask?.cancel()
        cancelAllUploads()
    }

    // MARK: - Attachments

    /// One upload the user can see and cancel while it is happening.
    struct PendingUpload: Identifiable, Equatable {
        let id = UUID()
        let filename: String
        /// `nil` when the file could not be stat'd; the chip then shows no size.
        let byteCount: Int?
    }

    /// Uploads in flight, oldest first. Rendered as spinner chips beside the
    /// finished ones — an upload that shows nothing until it lands reads as a
    /// no-op on a slow link, and the user picks the file again.
    private(set) var pendingUploads: [PendingUpload] = []
    @ObservationIgnored private var uploadTasks: [PendingUpload.ID: Task<Void, Never>] = [:]
    /// The tail of the upload queue. Uploads MUST run one at a time: the limits
    /// are per draft, and two concurrent uploads each measure the total against
    /// the same pre-upload draft, so a pair that only fits individually would both
    /// pass the check and the server would 413 the second.
    @ObservationIgnored private var uploadChain: Task<Void, Never>?
    @ObservationIgnored private var enqueuedCount = 0

    /// Runs the open panel and uploads whatever the user picked.
    ///
    /// The app is sandboxed: the URL the panel hands back carries the read grant,
    /// so it is passed straight to the outbox rather than copied or re-derived.
    func addAttachments() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Attach"
        guard await panel.begin() == .OK else { return }
        await attach(panel.urls)
    }

    /// Attaches a batch — a multi-file open panel, drop or paste.
    ///
    /// Every file gets its chip at once and the uploads then run one after
    /// another: the user sees what they dropped immediately, and the per-draft
    /// limit is still measured against a draft that includes the file before it.
    func attach(_ urls: [URL], staged: Set<URL> = []) async {
        // ONE filter for every entry point (panel, drop, paste): a directory
        // reaches the outbox as an unreadable file, and a promise-backed or
        // remote URL as nothing at all.
        let files = urls.filter(Self.isAttachableFile)
        if files.isEmpty {
            if !urls.isEmpty { status = .failed("Herald can attach files, not folders.") }
            return
        }
        for url in staged.subtracting(files) { AttachmentScratchpad.discard(url) }
        let tasks = files.map { enqueue($0, isStaged: staged.contains($0)) }
        for task in tasks { await task.value }
    }

    /// Whether a URL names a real, readable file.
    ///
    /// The scope is claimed FIRST: a URL that only becomes reachable inside its
    /// security scope would otherwise stat as missing and be filtered away, and
    /// the drop would silently do nothing.
    private static func isAttachableFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    /// - Parameter isStaged: true for a file Herald itself wrote to the scratchpad
    ///   (a pasted image), which is deleted once the upload is over. A file the
    ///   USER chose is never deleted.
    func attach(_ url: URL, isStaged: Bool = false) async {
        await attach([url], staged: isStaged ? [url] : [])
    }

    /// Puts the chip up now and the upload at the end of the queue.
    private func enqueue(_ url: URL, isStaged: Bool) -> Task<Void, Never> {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        let pending = PendingUpload(filename: url.lastPathComponent, byteCount: size)
        pendingUploads.append(pending)
        let previous = uploadChain
        enqueuedCount += 1
        let position = enqueuedCount
        let task = Task {
            await previous?.value
            await self.upload(url, as: pending, isStaged: isStaged)
            // Release the chain once the LAST enqueued upload is done, so a
            // composer left open for a day does not hold every finished Task.
            if position == self.enqueuedCount { self.uploadChain = nil }
        }
        uploadChain = task
        uploadTasks[pending.id] = task
        return task
    }

    private func upload(_ url: URL, as pending: PendingUpload, isStaged: Bool) async {
        // Cancelled while queued behind another upload: nothing has been read or
        // sent, so this is a clean no-op — minus the staged file, which is ours.
        guard !Task.isCancelled else {
            if isStaged { AttachmentScratchpad.discard(url) }
            return
        }
        // A dropped or panel-picked URL arrives with a sandbox extension already
        // consumed, but a bookmark-derived one would not; claiming access is
        // correct for both and a no-op for the first.
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            if isStaged { AttachmentScratchpad.discard(url) }
            pendingUploads.removeAll { $0.id == pending.id }
            uploadTasks[pending.id] = nil
        }

        status = .saving
        let sent = draft
        do {
            let saved = try await outbox.attach(url, to: sent)
            // Adopted even when this upload was CANCELLED: the bytes reached the
            // server, so the local attachment list has to include them or every
            // later per-draft total is measured short and the server 413s the
            // next upload. Cancellation only suppresses the status change.
            draft.adoptServerState(from: saved, sent: sent)
            // Published for the same reason it is adopted above, cancellation
            // included: the bytes are on the server draft, so the Drafts folder's
            // copy has to say so too.
            publishDraftState()
            if status == .saving, !Task.isCancelled { status = .idle }
        } catch {
            logger.warning("Attachment failed: \(error.logCode, privacy: .public)")
            guard !Task.isCancelled else { return }
            status = .failed(error.localizedDescription)
        }
    }

    /// Stops waiting on an upload and takes its chip away.
    ///
    /// The request itself may still land — the server has no cancel — so the
    /// attachment can still appear as a finished chip a moment later. That is
    /// honest: the file IS on the draft, and the same remove button takes it off.
    func cancelUpload(_ id: PendingUpload.ID) {
        uploadTasks[id]?.cancel()
        uploadTasks[id] = nil
        pendingUploads.removeAll { $0.id == id }
        if status == .saving, pendingUploads.isEmpty { status = .idle }
    }

    private func cancelAllUploads() {
        for id in Array(uploadTasks.keys) { cancelUpload(id) }
    }

    /// Waits for every queued upload. Called before sending, so a message can
    /// never leave without the file the user just dropped on it.
    func waitForUploads() async {
        await uploadChain?.value
    }

    /// Files dropped on the window. Directories are ignored rather than walked:
    /// dropping a folder on a mail composer means "the files in it" to almost
    /// nobody, and a deep tree is a very expensive misunderstanding.
    func drop(_ urls: [URL]) async {
        await attach(urls)
    }

    /// ⌘V: attaches file URLs, or writes a pasted image to scratch and attaches that.
    ///
    /// - Returns: whether the paste was consumed. `false` means the pasteboard held
    ///   nothing attachable and the caller must forward ⌘V to the text view — a
    ///   composer that eats plain-text paste is worse than one that never attaches.
    @discardableResult
    func paste(_ contents: PasteboardContents) async -> Bool {
        let pasted = AttachmentPasteboard.attachments(from: contents)
        guard !pasted.isEmpty else { return false }

        var urls: [URL] = []
        var staged: Set<URL> = []
        for item in pasted {
            switch item {
            case .file(let url):
                urls.append(url)
            case .image(let image, let filename):
                do {
                    // Off-main: a full-screen bitmap off the pasteboard is tens of
                    // MiB, and writing it here would freeze the window mid-⌘V.
                    let url = try await Task.detached(priority: .userInitiated) { @Sendable in
                        try AttachmentScratchpad.stage(image.data, filename: filename)
                    }.value
                    urls.append(url)
                    staged.insert(url)
                } catch {
                    logger.warning("Could not stage a pasted image: \(error.localizedDescription, privacy: .private)")
                    status = .failed("Herald could not read the pasted image.")
                }
            }
        }
        guard !urls.isEmpty else { return true }
        await attach(urls, staged: staged)
        return true
    }

    func removeAttachment(_ attachment: DraftAttachment) async {
        let sent = draft
        do {
            let saved = try await outbox.removeAttachment(attachment.id, from: sent)
            draft.adoptServerState(from: saved, sent: sent)
            publishDraftState()
        } catch {
            logger.warning("Removing an attachment failed: \(error.logCode, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }
}
