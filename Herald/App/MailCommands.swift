import HeraldKit
import SwiftUI

/// Focus plumbing so the menu bar can act on whatever window is key.
struct MailModelFocusKey: FocusedValueKey {
    typealias Value = MailViewModel
}

/// The selection, published as PRIMITIVE focused values rather than read off the
/// focused view-model.
///
/// `@FocusedValue` re-evaluates the commands when the *value* changes, and for a
/// reference type that means when the reference changes. The view-model is a
/// single long-lived object, so selecting a row mutated it without changing the
/// focused value at all: the Message menu could keep the enablement and the
/// titles ("Mark as Read", "Star") it had when the window took focus. `String?`
/// and `Bool?` change whenever the selection does, so the menu tracks it.
struct SelectedThreadIDKey: FocusedValueKey {
    typealias Value = String
}

struct SelectedMessageIDKey: FocusedValueKey {
    typealias Value = String
}

struct SelectedIsUnreadKey: FocusedValueKey {
    typealias Value = Bool
}

struct SelectedIsStarredKey: FocusedValueKey {
    typealias Value = Bool
}

/// The folder the key window is listing. Same reason as the keys above: the
/// Trash scope renames Archive and drops Move to Trash (issue #8).
struct SelectionFolderKey: FocusedValueKey {
    typealias Value = ConversationFolder
}

extension FocusedValues {
    var mailModel: MailViewModel? {
        get { self[MailModelFocusKey.self] }
        set { self[MailModelFocusKey.self] = newValue }
    }

    var selectedThreadID: String? {
        get { self[SelectedThreadIDKey.self] }
        set { self[SelectedThreadIDKey.self] = newValue }
    }

    var selectedMessageID: String? {
        get { self[SelectedMessageIDKey.self] }
        set { self[SelectedMessageIDKey.self] = newValue }
    }

    var selectedIsUnread: Bool? {
        get { self[SelectedIsUnreadKey.self] }
        set { self[SelectedIsUnreadKey.self] = newValue }
    }

    var selectedIsStarred: Bool? {
        get { self[SelectedIsStarredKey.self] }
        set { self[SelectedIsStarredKey.self] = newValue }
    }

    var selectionFolder: ConversationFolder? {
        get { self[SelectionFolderKey.self] }
        set { self[SelectionFolderKey.self] = newValue }
    }
}

/// Every mail action has a menu item and a shortcut — a macOS app must be usable
/// without the mouse (and Full Keyboard Access relies on the menus).
///
/// The menu owns ⌘⇧K (Get New Mail) and ⌘⇧A (Archive); the single-key `e` and
/// `⌫` are deliberately NOT here — a bare key in a menu or on a toolbar button is
/// window-global and fires while the user is typing in the search field. Those
/// live on the conversation list as focus-scoped `.onKeyPress` handlers.
struct MailCommands: Commands {
    let environment: AppEnvironment
    @FocusedValue(\.mailModel) private var model: MailViewModel?
    @FocusedValue(\.selectedThreadID) private var selectedThreadID: String?
    @FocusedValue(\.selectedMessageID) private var selectedMessageID: String?
    @FocusedValue(\.selectedIsUnread) private var selectedIsUnread: Bool?
    @FocusedValue(\.selectedIsStarred) private var selectedIsStarred: Bool?
    @FocusedValue(\.selectionFolder) private var selectionFolder: ConversationFolder?

    var body: some Commands {
        // App menu → "Check for Updates…" directly under "About Herald" (Sparkle, t-8a1c0026).
        // `after: .appInfo`, never `replacing:` — replacing that group would silently drop the
        // About item. The item renders itself reactively and stays disabled on builds with no
        // Sparkle signing key (CI, unsigned, test hosts).
        CommandGroup(after: .appInfo) {
            UpdateService.shared.checkForUpdatesMenuItem { [environment] in
                environment.record(.updateCheckRequested)
            }
        }

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
                .disabled(!hasMessage)
            Button("Reply All") { model?.requestCompose(.replyAll) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!hasMessage)
            Button("Forward") { model?.requestCompose(.forward) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!hasMessage)

            Divider()

            // ⌘⇧A archives, except in Trash and Archive where archiving is a
            // server no-op: there the same key puts the thread back (upstream
            // 1.3.4 restore/unarchive — issues #7, #8).
            Button(restoreAction == nil ? "Archive" : restoreTitle) {
                perform(restoreAction ?? .archive)
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!hasSelection)
            // ⌘⌫, as in Mail. A bare ⌫ would trash the selected thread while the
            // user was backspacing in the search field. Disabled in the Trash,
            // where the server would do nothing.
            Button("Move to Trash") { perform(.trash) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!hasSelection || isTrashScope)

            Divider()

            Button(markReadTitle) { toggleRead() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(!hasSelection)
            Button(starTitle) { toggleStar() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!hasSelection)

            // House rule: every mail action has a menu item. Labelling was
            // reachable only from the row's context menu, so a keyboard-only or
            // Full-Keyboard-Access user could not file a thread at all.
            //
            // The context menu's own view, reused rather than re-spelled: one
            // source for the toggle rows, their state and their writes. It draws
            // its own leading Divider and renders nothing when the workspace has
            // no labels.
            if let model, let selectedThreadID {
                LabelMenu(model: model, threadID: selectedThreadID)
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("Add Account…") { environment.presentsAddAccount = true }
            // Names the account: with several signed in, an unqualified "Sign
            // Out" is ambiguous about which server it burns.
            Button(environment.signOutMenuTitle) {
                Task { await environment.signOut(accountID: environment.selectedAccountID) }
            }
            .disabled(environment.mail == nil)
        }
    }

    private var hasSelection: Bool { selectedThreadID != nil }
    private var isTrashScope: Bool { selectionFolder == .trash }

    private var restoreAction: ConversationAction? {
        MailViewModel.restoreAction(in: selectionFolder)
    }

    private var restoreTitle: String { MailViewModel.restoreActionTitle(in: selectionFolder) }
    private var hasMessage: Bool { selectedMessageID != nil }

    private var markReadTitle: String {
        (selectedIsUnread ?? true) ? "Mark as Read" : "Mark as Unread"
    }

    private var starTitle: String {
        (selectedIsStarred ?? false) ? "Unstar" : "Star"
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
