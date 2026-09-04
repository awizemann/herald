import Foundation
import HeraldKit

extension MailViewModel {
    // MARK: - Usage

    /// The event vocabulary's name for a message-level action.
    nonisolated static func usageAction(for action: MessageAction) -> UsageMessageAction {
        switch action {
        case .read: .read
        case .unread: .unread
        case .star: .star
        case .unstar: .unstar
        case .archive: .archive
        case .unarchive: .unarchive
        case .trash: .trash
        case .restore: .restore
        }
    }

    /// The same, for the conversation-level verbs.
    nonisolated static func usageAction(for action: ConversationAction) -> UsageMessageAction {
        switch action {
        case .read: .read
        case .unread: .unread
        case .star: .star
        case .unstar: .unstar
        case .archive: .archive
        case .unarchive: .unarchive
        case .trash: .trash
        case .restore: .restore
        }
    }

    /// A failed action, reduced to its kind. Anything that is not a
    /// ``MailAPIError`` lands on `other` — the action failed and that is worth
    /// counting; the error itself, message and all, still never leaves.
    private func recordActionFailure(_ action: UsageMessageAction, _ error: any Error) {
        record(.actionFailed(action: action, kind: UsageMailErrorKind(anyError: error)))
    }

    // MARK: - Actions

    func perform(_ action: MessageAction, on messageID: String) async {
        record(.messageActionPerformed(
            action: Self.usageAction(for: action), scope: .message, count: .one
        ))
        do {
            try await actions.perform(action, on: messageID, accountID: accountID)
        } catch {
            actionError = error.localizedDescription
            recordActionFailure(Self.usageAction(for: action), error)
        }
        await reloadAfterAction(threadID: threadMessages.first(where: { $0.id == messageID })?.threadID)
    }

    /// - Parameter scope: what the user acted on. `.conversation` for a row or a
    ///   context menu, `.selection` for the menu-bar verbs that act on whatever
    ///   is selected.
    func perform(
        _ action: ConversationAction,
        onThread threadID: String,
        scope: UsageActionScope = .conversation
    ) async {
        // Trashing what is already trashed is a server no-op; do not pretend.
        if isTrashScope, action == .trash { return }
        await performConversationAction(action, onThread: threadID, scope: scope)
    }

    /// Whether the list the user is looking at is the Trash.
    var isTrashScope: Bool { selection.folder == .trash }

    /// Whether "Archive" does anything here. The server only archives messages
    /// in inbox/catchall (conversation-queries.ts), so in Trash and Archive the
    /// affordance is dropped in favour of the restore one below.
    var offersArchiveAction: Bool {
        selection.folder != .trash && selection.folder != .archived
    }

    /// The "put back" verb for the folder being looked at, or nil where nothing
    /// can be put back. Upstream 1.3.4 added both; each is a server no-op unless
    /// the request's `folder` matches the one it undoes, which is exactly the
    /// folder the user is looking at.
    var restoreAction: ConversationAction? { Self.restoreAction(in: selection.folder) }

    /// Both verbs land the thread back in inbox/sent/catchall, so the Archive
    /// folder's says where it goes and the Trash's says what it undoes.
    var restoreActionTitle: String { Self.restoreActionTitle(in: selection.folder) }

    /// Shared with ``MailCommands``, which only has the focused folder value —
    /// one rule, so the menu and the list can never name different verbs.
    nonisolated static func restoreAction(in folder: ConversationFolder?) -> ConversationAction? {
        switch folder {
        case .trash: .restore
        case .archived: .unarchive
        default: nil
        }
    }

    nonisolated static func restoreActionTitle(in folder: ConversationFolder?) -> String {
        folder == .trash ? "Put Back" : "Move to Inbox"
    }

    /// Whether "Move to Trash" is worth offering at all: in the Trash it is a
    /// no-op, so the row/menu/toolbar simply do not show it.
    var offersTrashAction: Bool { !isTrashScope }

    private func performConversationAction(
        _ action: ConversationAction,
        onThread threadID: String,
        scope: UsageActionScope
    ) async {
        record(.messageActionPerformed(
            action: Self.usageAction(for: action), scope: scope, count: .one
        ))
        // Where the row sits in the list the user is looking at, captured BEFORE
        // it disappears: archiving the message you are reading has to move to the
        // next one, the way every mail client does, not empty the reading pane.
        let removedIndex = Self.removesRow(action) && threadID == selectedThreadID
            ? presentedConversations.firstIndex { $0.id == threadID }
            : nil
        do {
            try await actions.perform(
                action,
                onConversation: threadID,
                in: selection.folder,
                accountID: accountID,
                // A server-search hit has no cached messages, so the service has
                // no message id to address the server with; the row itself does.
                representativeMessageID: conversation(withID: threadID)?.latest.id
            )
            // The row leaves this scope, and a server-search row has no cache
            // entry to re-derive it from — drop the snapshot or the union puts
            // it straight back.
            if Self.removesRow(action) { dropServerResult(threadID) }
        } catch {
            actionError = error.localizedDescription
            recordActionFailure(Self.usageAction(for: action), error)
        }
        await reloadAfterAction(threadID: threadID, removedIndex: removedIndex)
    }

    /// Actions that take the row out of the scope it was acted on in.
    private nonisolated static func removesRow(_ action: ConversationAction) -> Bool {
        switch action {
        case .archive, .trash, .unarchive, .restore: true
        case .read, .unread, .star, .unstar: false
        }
    }

    /// The optimistic write already landed in the cache (and was reverted there if
    /// the server said no), so the slice reload is what makes either outcome visible.
    private func reloadAfterAction(threadID: String?, removedIndex: Int? = nil) async {
        await reloadConversations()
        if let removedIndex { advanceSelection(pastRowAt: removedIndex) }
        if let threadID, threadID == selectedThreadID { await loadThread(threadID) }
        // Herald's own follow-up pass, not the Refresh button: reporting it as
        // manual would make every action look like a refresh too.
        await refresh(trigger: .auto)
    }

    /// Moves the selection to the row that took the removed row's place, or to
    /// the last row when the removed one was at the end. Does nothing if the row
    /// is still presented — a failed action reverts, and the user should be left
    /// on the message that did not move.
    /// The advance is PROGRAMMATIC, so it never drills: the user deleted a row,
    /// they did not ask to open whatever took its place (issue #5 — deleting the
    /// row above a thread dropped the user inside that thread).
    private func advanceSelection(pastRowAt index: Int) {
        guard !presentedConversations.contains(where: { $0.id == selectedThreadID }) else { return }
        guard !presentedConversations.isEmpty else {
            select(nil, drill: false)
            return
        }
        select(presentedConversations[min(index, presentedConversations.count - 1)].id, drill: false)
    }

    /// Convenience for the commands: act on the current selection.
    func performOnSelection(_ action: ConversationAction) async {
        guard let threadID = selectedThreadID else { return }
        // Herald's list is single-selection, so the count is always one — the
        // bucket is what makes a future multi-select reportable without changing
        // the event.
        await perform(action, onThread: threadID, scope: .selection)
    }

    func toggleStar(_ row: ConversationSummary) async {
        await perform(row.isStarred ? .unstar : .star, onThread: row.id)
    }

    func toggleRead(_ row: ConversationSummary) async {
        await perform(row.isUnread ? .read : .unread, onThread: row.id)
    }

    /// Runs the save panel and writes the attachment. The API client stays private
    /// to the view-model; views ask for the action, not the bytes.
    func saveAttachment(_ attachment: Attachment) async {
        switch await AttachmentSaver.save(attachment, using: api) {
        case .saved:
            // No props: the filename, its size and its type are all off limits.
            record(.attachmentSaved)
        case .cancelled:
            break
        case .failed(let message):
            actionError = message
        }
    }

    func requestCompose(_ kind: ComposeRequest.Kind) {
        record(.composeOpened(kind: Self.usageComposeKind(for: kind)))
        composeRequest = ComposeRequest(
            kind: kind,
            messageID: selectedMessageID,
            mailboxID: selection.mailboxID ?? selectedMessage?.mailboxID
        )
    }

    nonisolated static func usageComposeKind(for kind: ComposeRequest.Kind) -> UsageComposeKind {
        switch kind {
        case .new: .new
        case .reply: .reply
        case .replyAll: .replyAll
        case .forward: .forward
        case .draft: .draft
        }
    }
}
