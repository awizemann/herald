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
        // Selected by `SidebarItem`, not by `FolderSelection`: Drafts is not a
        // conversation folder and cannot be expressed as one (see MailTheme.sidebarFolders).
        List(selection: Bindable(model).sidebarItem) {
            ForEach(MailTheme.sidebarFolders, id: \.self) { folder in
                FolderRow(
                    scope: MailViewModel.FolderSelection(
                        mailboxID: model.selection.mailboxID,
                        folder: folder
                    ),
                    unread: model.unreadCounts
                )
            }
            DraftsRow(count: model.draftCount)
            // Only when the workspace HAS labels: an empty section is a header
            // with nothing under it, and most instances start with none.
            if !model.labels.isEmpty {
                Section(MailTheme.labelsSectionTitle) {
                    ForEach(model.labels) { label in
                        // `threadCount` is a dictionary lookup into a structure
                        // built once per index reload. It used to walk every
                        // indexed thread PER LABEL, here in the body, on every
                        // render pass the sidebar took.
                        LabelRow(label: label, count: model.threadCount(forLabel: label.id))
                    }
                }
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
                model.pendingNavigationSource = .sidebar
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
        .accessibilityIdentifier(AccessibilityID.Sidebar.mailboxPicker)
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
        // Nobody clicked anything: this is the launch restoring the scope the
        // window was last showing. Routed through the model rather than assigned
        // here, because the launch view is reported exactly once and this path
        // races `start()` for the right to report it.
        model.restoreSelection(MailViewModel.FolderSelection(
            mailboxID: storedMailboxID,
            folder: model.selection.folder
        ))
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
                    .accessibilityIdentifier(AccessibilityID.Sidebar.accountName)
                SyncStatusLabel(
                    status: model.status,
                    lastSyncedAt: model.lastSyncedAt,
                    isReauthenticating: environment.isReauthenticating(accountID: model.accountID),
                    signIn: { [environment, accountID = model.accountID] in
                        Task { await environment.reauthenticate(accountID: accountID) }
                    }
                )
            }
            Spacer()
            // The help tag and the label belong on the MENU, not on its label
            // image: a `Menu`'s label view is not the accessibility element, so
            // labelling the image left VoiceOver announcing an unnamed pop-up
            // button and Voice Control with nothing to say.
            Menu {
                Button("Add Account…") { environment.presentsAddAccount = true }
                    .accessibilityIdentifier(AccessibilityID.Sidebar.addAccount)
                Button("Sign Out", role: .destructive) {
                    // This account only — the others keep syncing.
                    Task { await environment.signOut(accountID: model.accountID) }
                }
                .accessibilityIdentifier(AccessibilityID.Sidebar.signOut)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: MailTheme.hitTarget, height: MailTheme.hitTarget)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Account options")
            .accessibilityLabel("Account options")
            .accessibilityIdentifier(AccessibilityID.Sidebar.accountOptions)
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
            .accessibilityIdentifier(AccessibilityID.Sidebar.accountSwitcher)
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
    /// Whether a re-auth round trip is already running for this account.
    var isReauthenticating = false
    /// What clicking "Sign in again" does — the re-auth banner's Sign In.
    var signIn: () -> Void = {}

    /// What the slot offers besides its text.
    enum SignInAffordance: Equatable {
        /// Plain status text.
        case none
        /// "Sign in again" is a button.
        case available
        /// "Sign in again" is a button, disabled: a sign-in is already running,
        /// and a second click would only be refused by the policy — the control
        /// says so instead of looking dead.
        case inProgress
    }

    /// Pure and static so the rule is assertable without a rendered sidebar.
    nonisolated static func signInAffordance(
        for status: MailViewModel.SyncStatus,
        isReauthenticating: Bool
    ) -> SignInAffordance {
        guard case .needsReauth = status else { return .none }
        return isReauthenticating ? .inProgress : .available
    }

    var body: some View {
        let affordance = Self.signInAffordance(for: status, isReauthenticating: isReauthenticating)
        HStack(spacing: MailTheme.Spacing.xs) {
            if status == .syncing {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }
            if affordance == .none {
                statusText
            } else {
                // The red text the user is already looking at IS the way back
                // in — the same action as the banner's Sign In. Borderless, so
                // it draws exactly the text it replaces and the slot keeps its
                // height.
                Button(action: signIn) { statusText }
                    .buttonStyle(.borderless)
                    .disabled(affordance == .inProgress)
                    .help("Sign in to this account again")
                    .accessibilityLabel("Sign in again")
                    .accessibilityHint(
                        affordance == .inProgress
                            ? "Signing in is already in progress."
                            : "Opens the sign-in window for this account."
                    )
                    .accessibilityIdentifier(AccessibilityID.Sidebar.statusSignIn)
            }
        }
        // The slot, not the text, owns the height: whatever is inside it, nothing
        // below moves.
        .frame(height: MailTheme.statusSlotHeight, alignment: .leading)
        // Combined into one element while it is only text; a button stays its
        // own element so VoiceOver can find and press it.
        .accessibilityElement(children: affordance == .none ? .combine : .contain)
        .accessibilityIdentifier(AccessibilityID.Sidebar.status)
    }

    private var statusText: some View {
        Text(MailViewModel.statusDescription(for: status, lastSyncedAt: lastSyncedAt))
            .font(isProblem ? .caption.bold() : .caption)
            .foregroundStyle(isProblem ? MailTheme.failure : MailTheme.syncing)
            .lineLimit(1)
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

/// The Drafts item. A sibling of the folder rows on screen and a different thing
/// underneath: its badge is a TOTAL (drafts are never unread), not an unread count.
private struct DraftsRow: View {
    let count: Int

    var body: some View {
        Label(MailTheme.draftsTitle, systemImage: MailTheme.draftsSymbol)
            .badge(count)
            .tag(MailViewModel.SidebarItem.drafts)
            .accessibilityLabel(
                count > 0 ? "\(MailTheme.draftsTitle), \(count) drafts" : MailTheme.draftsTitle
            )
    }
}

/// One workspace label. It lists across folders, so it carries no unread badge:
/// the counts the sidebar shows are per (mailbox, folder) scope and a label is
/// neither.
///
/// The tag glyph is drawn in the label's colour, and the NAME is always there —
/// the colour is never the only way to tell two labels apart.
private struct LabelRow: View {
    let label: MailLabel
    /// Cached threads carrying the label — the ones opening it will actually
    /// list, not the raw assignment rows. A TOTAL, like the Drafts row's badge
    /// and unlike the folders' unread counts — see `threadCount(forLabel:)`.
    let count: Int

    var body: some View {
        Label {
            Text(label.name).lineLimit(1)
        } icon: {
            Image(systemName: MailTheme.labelSymbol)
                .foregroundStyle(MailTheme.labelTint(for: label.color))
        }
        .badge(count)
        .tag(MailViewModel.SidebarItem.label(label.id))
        .accessibilityLabel(
            count > 0 ? "\(label.name) label, \(count) conversations" : "\(label.name) label"
        )
    }
}

private struct FolderRow: View {
    let scope: MailViewModel.FolderSelection
    let unread: [MailViewModel.FolderSelection: Int]

    var body: some View {
        let count = unread[scope] ?? 0
        Label(MailTheme.title(for: scope.folder), systemImage: MailTheme.symbol(for: scope.folder))
            .badge(count)
            .tag(MailViewModel.SidebarItem.folder(scope))
            .accessibilityLabel(
                count > 0
                    ? "\(MailTheme.title(for: scope.folder)), \(count) unread"
                    : MailTheme.title(for: scope.folder)
            )
    }
}
