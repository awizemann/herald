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
        let ids = Set(labelIDsByThread[threadID] ?? [])
        guard !ids.isEmpty else { return [] }
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
    /// Derived from the same index the chips read, so it costs nothing extra, and
    /// it is a TOTAL rather than an unread count: a label spans folders, where
    /// every other sidebar badge counts one (mailbox, folder) scope.
    func threadCount(forLabel labelID: String) -> Int {
        labelIDsByThread.values.reduce(into: 0) { total, ids in
            if ids.contains(labelID) { total += 1 }
        }
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
    }

    /// Rebuilds the thread → labels index the row chips read.
    ///
    /// One fetch for the whole account, not one per row: the index is small (a
    /// join table over a workspace's handful of labels) and the list draws chips
    /// on every visible row.
    func reloadLabelIndex() async {
        do {
            let index = try await store.labelIDsByThread(accountID: accountID)
            guard !Task.isCancelled else { return }
            labelIDsByThread = index
        } catch {
            logger.error("Label index load failed: \(error.localizedDescription, privacy: .private)")
        }
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

    /// A label sweep changed something: the list, the membership, or both.
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
    /// Entering asks the engine for a fresh sweep, for the same reason opening
    /// Drafts asks for a fresh drafts poll: the sweep runs on a deliberately slow
    /// interval precisely because nobody is usually looking at it.
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
        await reloadLabelIndex()
        await reloadSelectedMessageLabels()
        // The listing IS the membership when a label is on screen: a thread that
        // just lost the label has to leave it, and one that gained it appear.
        if selectedLabelID != nil { await reloadConversations() }
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
        await reloadLabelIndex()
        await reloadSelectedMessageLabels()
        if selectedLabelID != nil { await reloadConversations() }
    }
}
