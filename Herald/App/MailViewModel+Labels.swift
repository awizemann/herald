import Foundation
import HeraldKit
import OSLog

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "MailViewModelLabels")

extension MailViewModel {
    // MARK: - Reads

    /// The label behind an id, or `nil` for one this account no longer caches (a
    /// label deleted in the web app between two sweeps).
    func label(withID id: String) -> MailLabel? {
        labels.first { $0.id == id }
    }

    /// The labels a conversation row draws, in the sidebar's order so two rows
    /// carrying the same labels never show them in different orders.
    func labels(forThread threadID: String) -> [MailLabel] {
        guard let ids = labelIDsByThread[threadID], !ids.isEmpty else { return [] }
        return labels.filter { ids.contains($0.id) }
    }

    /// The labels on the message the reading pane is showing.
    var selectedMessageLabels: [MailLabel] {
        let ids = Set(selectedMessageLabelIDs)
        guard !ids.isEmpty else { return [] }
        return labels.filter { ids.contains($0.id) }
    }

    /// How many cached threads carry a label — the sidebar's badge.
    ///
    /// A precomputed lookup, NOT a walk of the index: the sidebar asks once per
    /// label per render pass and this used to be a scan of every indexed thread
    /// each time, inside the view body.
    ///
    /// It is a TOTAL rather than an unread count — a label spans folders, where
    /// every other sidebar badge counts one (mailbox, folder) scope — and it
    /// counts threads the by-label listing can RESOLVE rather than assignment
    /// rows, which is the rule `MailStore.replaceAssignments` sets out. See
    /// `MailStore.labelIndex(accountID:)` for how the two are reconciled.
    func threadCount(forLabel labelID: String) -> Int {
        labelThreadCounts[labelID] ?? 0
    }

    /// Whether a thread already carries a label — what the context menu's
    /// checkmark and its add/remove verb read off.
    func threadHasLabel(_ labelID: String, threadID: String) -> Bool {
        labelIDsByThread[threadID]?.contains(labelID) ?? false
    }

    /// The label the middle column is listing, if any.
    var selectedLabel: MailLabel? {
        selectedLabelID.flatMap { label(withID: $0) }
    }

    // MARK: - Loads

    func reloadLabels() async {
        do {
            let loaded = try await store.labels(accountID: accountID)
            guard !Task.isCancelled else { return }
            labels = loaded
        } catch {
            logger.error("Label load failed: \(error.localizedDescription, privacy: .private)")
            return
        }
        // A label that was deleted in the web app must not strand the user in a
        // listing that can never be filled again.
        if let selectedLabelID, !labels.contains(where: { $0.id == selectedLabelID }) {
            showLabel(nil)
        }
        // An account whose workspace has no labels draws no chips and no badges,
        // so nothing on screen is waiting on the sweep.
        await updateLabelSurfaceVisibility()
    }

    /// Writes the label membership EMBEDDED in summaries the VIEW fetched
    /// directly — the single-message route and the thread route — and redraws the
    /// chips if anything moved.
    ///
    /// The sync engine covers every summary that goes through the cache; these
    /// two routes do not, because the view reads them for display and never
    /// stores the message. The membership they carry is still the freshest
    /// statement the app has, and it is free — the request was made anyway.
    ///
    /// A no-op on a server that does not embed labels: every `labels` is `nil`
    /// there and ``MailStore/applyEmbeddedLabels(from:accountID:)`` skips it.
    func storeEmbeddedLabels(of summaries: [MessageSummary]) async {
        do {
            guard try await store.applyEmbeddedLabels(from: summaries, accountID: accountID) else { return }
            guard !Task.isCancelled else { return }
            await reloadLabelIndex()
            await reloadSelectedMessageLabels()
        } catch {
            logger.error("Embedded label write failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Rebuilds the thread → labels index the row chips read, AND the per-label
    /// counts the sidebar badges read.
    ///
    /// One store call for the whole account, not one per row: the index is small
    /// (a join table over a workspace's handful of labels) and the list draws
    /// chips on every visible row. Both structures come out of the same single
    /// pass over the assignment rows, so the badges cost the view nothing.
    func reloadLabelIndex() async {
        labelIndexReloadCount += 1
        do {
            let index = try await store.labelIndex(accountID: accountID)
            guard !Task.isCancelled else { return }
            labelIDsByThread = index.idsByThread
            labelThreadCounts = index.threadCounts
        } catch {
            logger.error("Label index load failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Tells the sync engine whether anything on screen is showing labels, which
    /// is what decides how often the membership sweep runs.
    ///
    /// It only decides anything on a pre-1.4.2 server, where the sweep is the
    /// only membership source: there it is one `GET /messages?labelId=` page-walk
    /// PER label and the single most expensive idle thing Herald does, so it
    /// earns its 120s cadence only while someone can see the result. Against a
    /// server that embeds labels on message rows the engine ignores this signal
    /// and holds the sweep to its reconciliation interval — which is the engine's
    /// call to make, so the view-model keeps reporting the same fact either way.
    /// Two ways the surface is visible:
    ///
    /// - a label LISTING is open — the rows on screen ARE the membership; or
    /// - the account has labels at all AND the app is frontmost — the sidebar is
    ///   drawing a badge per label and the list a chip per row.
    ///
    /// Deliberately not finer than that. A "is the sidebar collapsed, is the list
    /// scrolled past its chips" signal would be several pieces of view state
    /// racing one actor hop, for a cadence whose whole job is to be approximately
    /// right; and getting it WRONG in the quiet direction shows the user stale
    /// chips with no way to tell. Backgrounded-with-labels and no-labels-at-all
    /// are the cases that actually matter, and both are unambiguous.
    func updateLabelSurfaceVisibility() async {
        let visible = selectedLabelID != nil || (!labels.isEmpty && isAppActive)
        guard visible != isLabelSurfaceVisible else { return }
        isLabelSurfaceVisible = visible
        await sync?.setLabelSurfaceVisible(visible)
    }

    /// Reloads the labels on the message the reading pane is showing.
    func reloadSelectedMessageLabels() async {
        guard let messageID = selectedMessageID else {
            selectedMessageLabelIDs = []
            return
        }
        do {
            let ids = try await store.labelIDs(messageID: messageID, accountID: accountID)
            guard !Task.isCancelled, selectedMessageID == messageID else { return }
            selectedMessageLabelIDs = ids
        } catch {
            logger.error("Message label load failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Labels moved: the list, the membership, or both — from the reconciliation
    /// sweep, or from the embedded labels a pass upserted with its message rows.
    func applyLabelsChanged() async {
        await reloadLabels()
        // Only the label listing is DERIVED from membership, so a folder listing
        // is not reloaded for a label edit elsewhere — but its INDEX still is, or
        // the chips on the rows already on screen would be a sweep behind.
        // `reloadConversations` refreshes the index itself (before it publishes
        // the rows), so the label listing takes that path instead of both.
        if selectedLabelID != nil {
            await reloadConversations()
        } else {
            await reloadLabelIndex()
        }
        await reloadSelectedMessageLabels()
    }

    // MARK: - Navigation

    /// Enters (or, with `nil`, leaves) a label listing.
    ///
    /// Entering asks the engine for a fresh reconciliation, for the same reason
    /// opening Drafts asks for a fresh drafts poll: it runs on a deliberately slow
    /// interval precisely because nobody is usually looking at it — and it is the
    /// only thing that can bring in assignments for messages in folders this cache
    /// has never listed, which a label listing is exactly where you notice.
    func showLabel(_ labelID: String?) {
        guard labelID != selectedLabelID else { return }
        selectedLabelID = labelID
        // Both live in the middle column; a drilled-in thread would otherwise be
        // drawn over the listing the user just asked for.
        leaveThreadSilently()
        showDrafts(false, silently: true)
        selectedThreadID = nil
        // The rows a server search matched answer a folder's question, not this
        // label's.
        cancelServerSearch()
        // Deliberately NOT reported: the usage vocabulary (`UsageViewKind`) has no
        // label view, and inventing one means a new wire name and a new fixture id
        // — an analytics change that belongs with the rest of the vocabulary, not
        // smuggled in with a feature. The pending source is still CONSUMED, so a
        // sidebar click cannot leave a stale `via` for the next real navigation.
        _ = takeNavigationSource()
        // The presentation rule just changed, so the visible list is wrong until
        // it is recomputed — don't wait for the store round trip.
        refilter()
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            await self?.reloadConversations()
            // Entering a listing turns the fast sweep cadence on; leaving one may
            // turn it off again (only may — the sidebar's badges keep it on while
            // the app is frontmost).
            await self?.updateLabelSurfaceVisibility()
            guard labelID != nil else { return }
            await self?.sync?.refreshLabelsNow()
        }
    }

    // MARK: - Assignment

    /// Adds or removes one label on a thread, optimistically.
    ///
    /// The store moves first and the cache is reverted exactly on failure — the
    /// same contract as archive and star (``MailActionService``). The chips
    /// redraw off the index, so it is rebuilt on both paths.
    func setLabel(_ labelID: String, onThread threadID: String, assigned: Bool) async {
        do {
            try await actions.setLabel(
                labelID,
                onConversation: threadID,
                accountID: accountID,
                assigned: assigned,
                representativeMessageID: conversation(withID: threadID)?.latest.id
            )
        } catch {
            logger.warning("Label change failed: \(error.localizedDescription, privacy: .private)")
            actionError = error.localizedDescription
        }
        await reloadIndexAfterLabelChange()
        await reloadSelectedMessageLabels()
    }

    /// The same, for the single message the reading pane is showing.
    func setLabel(_ labelID: String, onMessage messageID: String, assigned: Bool) async {
        do {
            try await actions.setLabel(
                labelID, onMessage: messageID, accountID: accountID, assigned: assigned
            )
        } catch {
            logger.warning("Label change failed: \(error.localizedDescription, privacy: .private)")
            actionError = error.localizedDescription
        }
        await reloadIndexAfterLabelChange()
        await reloadSelectedMessageLabels()
    }

    /// Republishes whatever a label write invalidated, ONCE.
    ///
    /// Inside a label listing the rows themselves are the membership — a thread
    /// that just lost the label has to leave, one that gained it has to appear —
    /// so the listing is reloaded; and `reloadConversations` rebuilds the index
    /// itself (before it publishes the rows, so the chips are never a frame
    /// behind). Doing both, as this used to, was two whole-account index reads
    /// and a redundant round trip per toggle. Outside a listing only the index
    /// moved, so only the index is reloaded.
    ///
    /// The same either/or `applyLabelsChanged` makes, for the same reason.
    private func reloadIndexAfterLabelChange() async {
        if selectedLabelID != nil {
            await reloadConversations()
        } else {
            await reloadLabelIndex()
        }
    }
}
