import HeraldKit
import SwiftUI

/// Account header + mailbox picker + ONE folder list for the picked scope.
///
/// The old shape was "All Mailboxes" plus a section per mailbox, which grew a
/// full folder list per mailbox and pushed everything below the fold on an
/// account with more than two or three of them.
struct SidebarView: View {
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: MailViewModel

    /// The picked mailbox, per account, so relaunch comes back to where the user
    /// was. `""` means "All mailboxes" — `AppStorage` has no optional String and
    /// a sentinel beats a second "did the user ever pick one" flag.
    @AppStorage private var storedMailboxID: String

    init(model: MailViewModel) {
        self.model = model
        _storedMailboxID = AppStorage(wrappedValue: "", Self.storageKey(accountID: model.accountID))
    }

    static func storageKey(accountID: String) -> String { "sidebar.mailbox.\(accountID)" }

    var body: some View {
        List(selection: $model.selection) {
            ForEach(MailTheme.sidebarFolders, id: \.self) { folder in
                FolderRow(
                    scope: MailViewModel.FolderSelection(
                        mailboxID: model.selection.mailboxID,
                        folder: folder
                    ),
                    unread: model.unreadCounts
                )
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                accountHeader
                AccountSwitcher()
                mailboxPicker
                Divider()
            }
        }
        // Restore once the mailbox list is known; a mailbox that no longer exists
        // falls back to "All mailboxes" rather than an empty scope forever.
        .task(id: model.mailboxes.map(\.id)) { restorePickedMailbox() }
    }

    // MARK: Picker

    /// Reads the model, writes BOTH the model and the store. The folder is
    /// preserved deliberately: picking a mailbox changes the scope, it is not a
    /// jump back to the inbox.
    private var pickedMailboxID: Binding<String> {
        Binding(
            get: { model.selection.mailboxID ?? "" },
            set: { newValue in
                storedMailboxID = newValue
                model.selection = MailViewModel.FolderSelection(
                    mailboxID: newValue.isEmpty ? nil : newValue,
                    folder: model.selection.folder
                )
            }
        )
    }

    private var mailboxPicker: some View {
        Picker(selection: pickedMailboxID) {
            Text(MailViewModel.allMailboxesPickerLabel(unread: model.pickerUnread(forMailbox: nil)))
                .tag("")
            ForEach(model.mailboxes) { mailbox in
                Text(
                    MailViewModel.pickerLabel(
                        for: mailbox,
                        unread: model.pickerUnread(forMailbox: mailbox.id)
                    )
                )
                .tag(mailbox.id)
            }
        } label: {
            Text("Mailbox")
        }
        .pickerStyle(.menu)
        .labelsHidden()
        // A `Picker` is a real pop-up button, so Full Keyboard Access reaches it
        // already — but with `labelsHidden()` it has nothing to announce, and
        // Voice Control nothing to say.
        .help("Choose which mailbox the folder list shows")
        .accessibilityLabel("Mailbox")
        .padding(.horizontal, MailTheme.Spacing.md)
        .padding(.bottom, MailTheme.Spacing.sm)
    }

    private func restorePickedMailbox() {
        guard !storedMailboxID.isEmpty else { return }
        guard model.mailboxes.contains(where: { $0.id == storedMailboxID }) else {
            // Access was revoked, or this is a different account's leftover key:
            // don't strand the user on a scope the store can never fill.
            if !model.mailboxes.isEmpty { storedMailboxID = "" }
            return
        }
        guard model.selection.mailboxID != storedMailboxID else { return }
        model.selection = MailViewModel.FolderSelection(
            mailboxID: storedMailboxID,
            folder: model.selection.folder
        )
    }

    // MARK: Header

    private var accountHeader: some View {
        HStack(spacing: MailTheme.Spacing.sm) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.accountLabel)
                    .font(.headline)
                    .lineLimit(1)
                SyncStatusLabel(status: model.status, lastSyncedAt: model.lastSyncedAt)
            }
            Spacer()
            // The help tag and the label belong on the MENU, not on its label
            // image: a `Menu`'s label view is not the accessibility element, so
            // labelling the image left VoiceOver announcing an unnamed pop-up
            // button and Voice Control with nothing to say.
            Menu {
                Button("Add Account…") { environment.presentsAddAccount = true }
                Button("Sign Out", role: .destructive) {
                    // This account only — the others keep syncing.
                    Task { await environment.signOut(accountID: model.accountID) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: MailTheme.hitTarget, height: MailTheme.hitTarget)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Account options")
            .accessibilityLabel("Account options")
        }
        .padding(.horizontal, MailTheme.Spacing.md)
        .padding(.vertical, MailTheme.Spacing.sm)
        .accessibilityElement(children: .contain)
    }
}

/// Picks which account the window shows.
///
/// Its OWN view, not a computed property of the sidebar: it reads every signed-in
/// account's unread count, and inlined it made a poll on a background account
/// invalidate the whole folder list of the account being read.
private struct AccountSwitcher: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        // Only worth the row when there is somewhere to switch TO — the header
        // already names the one account otherwise.
        if environment.accountIDs.count > 1 {
            Picker(selection: pickedAccountID) {
                ForEach(environment.accounts) { account in
                    Text(
                        AppEnvironment.accountPickerLabel(
                            for: account,
                            unread: environment.unreadCount(forAccount: account.id)
                        )
                    )
                    .tag(account.id)
                }
            } label: {
                Text("Account")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            // Same reason as the mailbox picker: `labelsHidden()` leaves the
            // pop-up button with nothing to announce.
            .help("Choose which account this window shows")
            .accessibilityLabel("Account")
            .padding(.horizontal, MailTheme.Spacing.md)
            .padding(.bottom, MailTheme.Spacing.sm)
        }
    }

    /// Non-optional for the `Picker`'s sake. It falls back to the first account
    /// rather than an empty sentinel: a selection with no matching tag logs
    /// "the selection is invalid" and draws a blank pop-up.
    private var pickedAccountID: Binding<Account.ID> {
        Binding(
            get: { environment.selectedAccountID ?? environment.accountIDs.first ?? "" },
            set: { newValue in
                guard !newValue.isEmpty else { return }
                environment.selectedAccountID = newValue
            }
        )
    }
}

/// The sync status, in a slot that is ALWAYS the same height.
///
/// It used to render `EmptyView()` when idle, so the line appeared on every poll
/// and vanished after it — pushing the picker and the whole folder list down and
/// back, twice per cadence tick.
struct SyncStatusLabel: View {
    let status: MailViewModel.SyncStatus
    let lastSyncedAt: Date?

    var body: some View {
        HStack(spacing: MailTheme.Spacing.xs) {
            if status == .syncing {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }
            Text(MailViewModel.statusDescription(for: status, lastSyncedAt: lastSyncedAt))
                .font(isProblem ? .caption.bold() : .caption)
                .foregroundStyle(isProblem ? MailTheme.failure : MailTheme.syncing)
                .lineLimit(1)
        }
        // The slot, not the text, owns the height: whatever is inside it, nothing
        // below moves.
        .frame(height: MailTheme.statusSlotHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Bold and a system red: caption-sized `.red` on the sidebar material does
    /// not clear 4.5:1, and this is the only signal that sync is broken.
    private var isProblem: Bool {
        switch status {
        case .failed, .needsReauth: true
        case .idle, .syncing: false
        }
    }
}

private struct FolderRow: View {
    let scope: MailViewModel.FolderSelection
    let unread: [MailViewModel.FolderSelection: Int]

    var body: some View {
        let count = unread[scope] ?? 0
        Label(MailTheme.title(for: scope.folder), systemImage: MailTheme.symbol(for: scope.folder))
            .badge(count)
            .tag(scope)
            .accessibilityLabel(
                count > 0
                    ? "\(MailTheme.title(for: scope.folder)), \(count) unread"
                    : MailTheme.title(for: scope.folder)
            )
    }
}
