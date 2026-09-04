import Foundation
import HeraldKit
import OSLog

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "MailViewModel")

/// What a compose window did to its server draft, reported back so the Drafts
/// folder reflects it immediately instead of at the next poll.
nonisolated enum DraftCacheEvent: Sendable {
    /// An autosave (or an attachment change) landed; this is the server's answer.
    case saved(Draft)
    /// The draft is gone from the server — sent, or discarded.
    case removed(String)
    /// The window closed but the draft lives on; release the poll's fence.
    case closed(String)
}

extension MailViewModel {
    // MARK: - Scope

    /// The title the window subtitle and the empty state use for whatever the
    /// middle column is currently listing.
    var scopeTitle: String {
        if isShowingDrafts { return MailTheme.draftsTitle }
        if let label = selectedLabel { return label.name }
        return MailTheme.title(for: selection.folder)
    }

    /// The sidebar's selection, mapped onto the two pieces of state that actually
    /// drive the UI. A computed binding rather than a stored `SidebarItem`, so
    /// ``selection`` stays the single source of the conversation scope and nothing
    /// downstream has to learn about drafts.
    var sidebarItem: SidebarItem {
        get {
            if isShowingDrafts { return .drafts }
            if let selectedLabelID { return .label(selectedLabelID) }
            return .folder(selection)
        }
        set {
            // Every write to this comes from the sidebar's `List(selection:)`.
            pendingNavigationSource = .sidebar
            switch newValue {
            case .drafts:
                showLabel(nil)
                pendingNavigationSource = .sidebar
                showDrafts(true)
            case .label(let labelID):
                showLabel(labelID)
            case .folder(let scope):
                // FIRST, and unconditionally: leaving a label listing for the
                // folder that is ALREADY in `selection` changes nothing below —
                // the `didSet` sees no change and never reloads — so the label's
                // rows would stay on screen under a folder row. `showLabel(nil)`
                // reloads the folder scope itself, and is a no-op otherwise.
                showLabel(nil)
                pendingNavigationSource = .sidebar
                // Leaving Drafts for the folder that is ALREADY selected is a
                // real navigation and reports itself here; `selection` then sees
                // no change and stays quiet. Leaving it for a DIFFERENT folder
                // must stay silent, or the old folder — the one being left — is
                // reported as a view that was never shown, ahead of the real
                // destination `selection` is about to report.
                showDrafts(false, silently: scope != selection)
                pendingNavigationSource = .sidebar
                selection = scope
                pendingNavigationSource = nil
            }
        }
    }

    /// Enters or leaves the Drafts folder.
    ///
    /// Entering asks the engine for a fresh drafts list: the drafts poll runs on
    /// its own slow interval precisely because nobody is usually looking, and
    /// this is the moment somebody is.
    /// - Parameter silently: suppresses the `view_shown` event, for callers that
    ///   are only passing THROUGH the drafts flag on their way somewhere they
    ///   report themselves (``revealConversation(threadID:)``).
    func showDrafts(_ showing: Bool, silently: Bool = false) {
        guard showing != isShowingDrafts else { return }
        isShowingDrafts = showing
        if !silently {
            recordViewShown(
                showing ? .drafts : Self.viewKind(for: selection.folder),
                via: takeNavigationSource()
            )
        }
        guard showing else { return }
        // Leaving a drilled-in thread behind would draw the thread pane over the
        // drafts list, since both live in the middle column. Silently: the view
        // being shown is the drafts list, already reported above.
        leaveThreadSilently()
        selectedDraftID = nil
        // Owned, and cancelled by `stop()`: an unstructured `Task` here outlives
        // the account graph that spawned it, and a signed-out account's view-model
        // must not be still loading rows behind the purge.
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            await self?.reloadDrafts()
            await self?.sync?.refreshDraftsNow()
        }
    }

    // MARK: - Loads

    func reloadDrafts() async {
        draftReloadCount += 1
        do {
            let rows = try await store.drafts(accountID: accountID)
            let count = try await store.draftCount(accountID: accountID)
            guard !Task.isCancelled else { return }
            drafts = rows
            draftCount = count
        } catch {
            logger.error("Draft load failed: \(error.localizedDescription, privacy: .private)")
            return
        }
        // A draft that vanished under the cursor (sent elsewhere, deleted) must
        // not leave a selection pointing at nothing.
        if let selectedDraftID, !drafts.contains(where: { $0.id == selectedDraftID }) {
            self.selectedDraftID = nil
        }
    }

    /// A drafts poll changed something. The badge is always affected; the list is
    /// only reloaded when it is on screen, so a background poll costs nothing.
    func applyDraftChanges(_ changes: ChangeSet) async {
        guard !changes.isEmpty else { return }
        await reloadDrafts()
    }

    // MARK: - Opening

    /// Opens the composer on a stored draft. Resolved from the CACHE — the whole
    /// draft including its version stamp is already there — so this costs no
    /// round trip and works offline.
    func openDraft(_ draftID: String) {
        record(.composeOpened(kind: .draft))
        composeRequest = ComposeRequest(kind: .draft, draftID: draftID)
    }

    /// ⏎ in the drafts list.
    func openSelectedDraft() {
        guard let selectedDraftID else { return }
        openDraft(selectedDraftID)
    }

    // MARK: - Deleting

    /// Deletes a draft: cache first, server after.
    ///
    /// Optimistic like every other mail action — the row goes now and comes back
    /// if the server refuses. The pre-delete copy is the revert material: the
    /// cache is the only place the draft still exists once the row is gone, so a
    /// failed delete has to be able to put exactly it back.
    func deleteDraft(_ draftID: String) async {
        // The user's intent, recorded once at the point they expressed it: the
        // delete is optimistic, and a server refusal is already covered by the
        // restore path below rather than by a second event.
        record(.draftDeleted)
        let restorable = try? await store.draft(id: draftID, accountID: accountID)
        do {
            try await store.deleteDraft(id: draftID, accountID: accountID)
        } catch {
            logger.error("Draft cache delete failed: \(error.localizedDescription, privacy: .private)")
        }
        await reloadDrafts()
        do {
            try await api.deleteDraft(id: draftID)
        } catch MailAPIError.notFound {
            // Already gone server-side; the optimistic delete was right.
            logger.info("Draft \(draftID, privacy: .public) was already deleted")
        } catch {
            logger.warning("Draft delete failed: \((error as? MailAPIError)?.logCode ?? "unknown", privacy: .public)")
            actionError = error.localizedDescription
            guard let restorable else { return }
            // Put back exactly what was removed, not a guess.
            try? await store.storeLocalDraft(restorable, accountID: accountID)
            // The restore is not a composer opening: drop the fence that
            // `storeLocalDraft` takes, or the poll could never tombstone this
            // draft again.
            await store.releaseOpenDraft(id: draftID, accountID: accountID)
            await reloadDrafts()
        }
    }

    func deleteSelectedDraft() async {
        guard let selectedDraftID else { return }
        await deleteDraft(selectedDraftID)
    }

    // MARK: - Composer write-through

    /// Mirrors what an open compose window did into the cache, so the Drafts
    /// folder is right immediately rather than up to one poll interval later.
    func applyDraftCacheEvent(_ event: DraftCacheEvent) async {
        do {
            switch event {
            case .saved(let draft):
                // Also fences the row: the poll must not delete a draft the
                // server has not listed yet, nor overwrite it with a listing
                // taken before this save.
                try await store.storeLocalDraft(draft, accountID: accountID)
            case .removed(let id):
                try await store.deleteDraft(id: id, accountID: accountID)
            case .closed(let id):
                await store.releaseOpenDraft(id: id, accountID: accountID)
                return // Nothing changed in the cache; nothing to reload.
            }
        } catch {
            logger.error("Draft cache write failed: \(error.localizedDescription, privacy: .private)")
            return
        }
        await reloadDrafts()
    }

    // MARK: - Presentation

    /// What a draft row shows where a conversation row shows its participants.
    nonisolated static func recipientsLabel(for draft: DraftSummary) -> String {
        draft.recipients.isEmpty ? "No recipients" : "To: " + draft.recipients.joined(separator: ", ")
    }

    nonisolated static func subjectLabel(for draft: DraftSummary) -> String {
        draft.subject.isEmpty ? "(No subject)" : draft.subject
    }

    /// What VoiceOver reads for one draft row: on screen the state is a date, a
    /// paperclip and two greyed lines, none of which say anything out loud.
    nonisolated static func accessibilitySummary(for draft: DraftSummary) -> String {
        var parts = [recipientsLabel(for: draft), subjectLabel(for: draft)]
        if draft.hasAttachments { parts.append("has attachments") }
        if !draft.snippet.isEmpty { parts.append(draft.snippet) }
        return parts.joined(separator: ", ")
    }
}
