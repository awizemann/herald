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
    /// Exposed so tests can await the debounce instead of sleeping on a wall clock.
    @ObservationIgnored private(set) var autosaveTask: Task<Void, Never>?

    init(context: ComposeContext, outbox: any Outboxing, autosaveDelay: Duration = .seconds(2)) {
        let draft = context.makeDraft()
        self.draft = draft
        self.initialDraft = draft
        self.outbox = outbox
        self.autosaveDelay = autosaveDelay
        self.toText = draft.to.joined(separator: ", ")
        self.ccText = draft.cc.joined(separator: ", ")
        self.bccText = draft.bcc.joined(separator: ", ")
        self.subject = draft.subject
        self.bodyText = draft.body
    }

    // MARK: - Presentation

    var windowTitle: String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Message" : trimmed
    }

    var attachments: [DraftAttachment] { draft.uploadedAttachments }

    var isBusy: Bool { status == .saving || status == .sending }

    /// Whether closing would lose work the server has not seen.
    var hasUnsavedChanges: Bool {
        guard draft.isDirty else { return false }
        return draft.to != initialDraft.to
            || draft.cc != initialDraft.cc
            || draft.bcc != initialDraft.bcc
            || draft.subject != initialDraft.subject
            || draft.body != initialDraft.body
            || !draft.pendingAttachments.isEmpty
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
        commitRecipients()
        guard !hasInvalidAddresses else {
            status = .failed(hint(for: .to) ?? hint(for: .cc) ?? hint(for: .bcc) ?? "Check the recipients.")
            return false
        }
        if draft.allRecipients.isEmpty, draft.mode.replyToMessageID == nil {
            status = .failed(OutboxError.noRecipients.localizedDescription)
            return false
        }
        status = .sending
        do {
            _ = try await outbox.send(draft)
            isClosed = true
            return true
        } catch {
            // Nothing is discarded: the window stays open with everything in it.
            logger.warning("Send failed: \(error.logCode, privacy: .public)")
            status = .failed(error.localizedDescription)
            return false
        }
    }

    func discard() async {
        autosaveTask?.cancel()
        isClosed = true
        do {
            try await outbox.discard(draft)
        } catch {
            logger.warning("Discarding the draft failed: \(error.logCode, privacy: .public)")
        }
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
        await saveNow()
        guard status.message == nil else { return } // Save failed: keep the window.
        isClosed = true
    }

    func close() {
        autosaveTask?.cancel()
        isClosed = true
    }

    /// Called from the window when it actually goes away, so no timer outlives it.
    func stop() {
        autosaveTask?.cancel()
    }

    // MARK: - Attachments

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
        for url in panel.urls {
            await attach(url)
        }
    }

    func attach(_ url: URL) async {
        status = .saving
        let sent = draft
        do {
            let saved = try await outbox.attach(url, to: sent)
            draft.adoptServerState(from: saved, sent: sent)
            if status == .saving { status = .idle }
        } catch {
            logger.warning("Attachment failed: \(error.logCode, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }

    func removeAttachment(_ attachment: DraftAttachment) async {
        let sent = draft
        do {
            let saved = try await outbox.removeAttachment(attachment.id, from: sent)
            draft.adoptServerState(from: saved, sent: sent)
        } catch {
            logger.warning("Removing an attachment failed: \(error.logCode, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }
}
