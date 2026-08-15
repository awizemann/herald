import HeraldKit
import SwiftUI

/// Focus plumbing so the menu bar can act on whatever window is key.
struct MailModelFocusKey: FocusedValueKey {
    typealias Value = MailViewModel
}

extension FocusedValues {
    var mailModel: MailViewModel? {
        get { self[MailModelFocusKey.self] }
        set { self[MailModelFocusKey.self] = newValue }
    }
}

/// Every mail action has a menu item and a shortcut — a macOS app must be usable
/// without the mouse (and Full Keyboard Access relies on the menus).
struct MailCommands: Commands {
    let environment: AppEnvironment
    @FocusedValue(\.mailModel) private var model: MailViewModel?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Message") { model?.requestCompose(.new) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model == nil)
            // ⇧⌘K, as in Mail: ⇧⌘R belongs to Reply All.
            Button("Get New Mail") { Task { await model?.refresh() } }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(model == nil)
        }

        CommandMenu("Message") {
            Button("Reply") { model?.requestCompose(.reply) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model?.selectedMessageID == nil)
            Button("Reply All") { model?.requestCompose(.replyAll) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model?.selectedMessageID == nil)
            Button("Forward") { model?.requestCompose(.forward) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model?.selectedMessageID == nil)

            Divider()

            Button("Archive") { perform(.archive) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!hasSelection)
            Button("Move to Trash") { perform(.trash) }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!hasSelection)

            Divider()

            Button(markReadTitle) { toggleRead() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(!hasSelection)
            Button(starTitle) { toggleStar() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!hasSelection)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Add Account…") { environment.presentsAddAccount = true }
            Button("Sign Out") { Task { await environment.signOut() } }
                .disabled(environment.mail == nil)
        }
    }

    private var selectedRow: ConversationSummary? { model?.selectedConversation }
    private var hasSelection: Bool { model?.selectedThreadID != nil }

    private var markReadTitle: String {
        (selectedRow?.isUnread ?? true) ? "Mark as Read" : "Mark as Unread"
    }

    private var starTitle: String {
        (selectedRow?.isStarred ?? false) ? "Unstar" : "Star"
    }

    private func perform(_ action: ConversationAction) {
        guard let model else { return }
        Task { await model.performOnSelection(action) }
    }

    private func toggleRead() {
        guard let model, let row = model.selectedConversation else { return }
        Task { await model.toggleRead(row) }
    }

    private func toggleStar() {
        guard let model, let row = model.selectedConversation else { return }
        Task { await model.toggleStar(row) }
    }
}
