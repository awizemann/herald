import HeraldKit
import SwiftUI

/// The account card at the top of the sidebar (handoff §3.1): tint avatar,
/// account name over "{N} domains · {sync status}", total unread and the
/// switcher chevron. It replaced the old account header, its ellipsis menu
/// and the account picker: the card's popover lists the accounts and offers
/// Add Account… and Settings…; Sign Out lives in Settings › Account.
///
/// Its OWN view, not part of the sidebar body: the popover reads every
/// signed-in account's unread count, and inlined it made a poll on a
/// background account invalidate the whole source list of the account being
/// read.
struct SidebarAccountCard: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openSettings) private var openSettings
    @Bindable var model: MailViewModel
    @State private var showsAccounts = false

    var body: some View {
        let tint = environment.accountTint(for: model.accountID)
        // Visible domains only: a hidden one is not in this sidebar at all.
        let domainCount = SidebarPresentation.visibleDomains(
            model.domains, accountID: model.accountID, preferences: environment.domainPreferencesObserved()
        ).count
        HStack(spacing: Self.gap) {
            SettingsAccountAvatar(label: model.accountLabel, tint: tint, diameter: Self.avatarDiameter)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.accountLabel)
                    .textStyle(MailTheme.Typography.headline)
                    .foregroundStyle(MailTheme.Color.ink)
                    .lineLimit(1)
                    .accessibilityIdentifier(AccessibilityID.Sidebar.accountName)
                HStack(spacing: 0) {
                    Text(SidebarPresentation.domainCountCaption(domainCount) + " · ")
                        .textStyle(MailTheme.Typography.caption)
                        .foregroundStyle(MailTheme.Color.ink3)
                        .lineLimit(1)
                        .fixedSize()
                    SyncStatusLabel(
                        status: model.status,
                        lastSyncedAt: model.lastSyncedAt,
                        isReauthenticating: environment.isReauthenticating(accountID: model.accountID),
                        signIn: { [environment, accountID = model.accountID] in
                            Task { await environment.reauthenticate(accountID: accountID) }
                        }
                    )
                }
            }
            Spacer(minLength: 0)
            if model.allDomainsInboxUnread > 0 {
                Text("\(model.allDomainsInboxUnread)")
                    .textStyle(MailTheme.Typography.metaStrong)
                    .foregroundStyle(MailTheme.Color.ink2)
                    .accessibilityHidden(true)
            }
            // The card's one real control: keyboard and VoiceOver reach the
            // popover through it. The rest of the card is a click target for
            // the mouse only (a Button around the whole card would swallow the
            // status slot's own "Sign in again" button).
            Button { showsAccounts.toggle() } label: {
                Image(systemName: MailTheme.Symbol.accountSwitcher)
                    .foregroundStyle(MailTheme.Color.ink3)
                    .frame(width: MailTheme.hitTarget, height: MailTheme.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Switch account, add an account or open Settings")
            .accessibilityLabel(Self.accessibilityLabel(
                account: model.accountLabel, unread: model.allDomainsInboxUnread
            ))
            .accessibilityHint("Shows your accounts, Add Account and Settings")
            .accessibilityIdentifier(AccessibilityID.Sidebar.accountCard)
        }
        .padding(.vertical, MailTheme.Spacing.sm)
        .padding(.leading, Self.gap)
        .padding(.trailing, MailTheme.Spacing.xs)
        .background(MailTheme.Color.surface, in: RoundedRectangle(cornerRadius: MailTheme.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: MailTheme.Radius.md)
                .strokeBorder(showsAccounts ? MailTheme.Color.line : MailTheme.Color.lineSoft, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: MailTheme.Radius.md))
        .onTapGesture { showsAccounts.toggle() }
        .popover(isPresented: $showsAccounts, arrowEdge: .bottom) {
            SidebarAccountPopover(
                currentAccountID: model.accountID,
                dismiss: { showsAccounts = false },
                openSettings: { openSettings() }
            )
        }
        .accessibilityElement(children: .contain)
        .padding(.horizontal, Self.gap)
        .padding(.bottom, Self.gap)
    }

    /// 10pt — the card's margin and inner gap (handoff: margin 0 10 10,
    /// padding 8 10, gap 10). Off the 4pt grid, so spelled as grid steps.
    static let gap = MailTheme.Spacing.sm + MailTheme.Spacing.xxs
    static let avatarDiameter: CGFloat = 26

    /// "Account: Wizemann Studio, 25 unread".
    nonisolated static func accessibilityLabel(account: String, unread: Int) -> String {
        SidebarPresentation.accessibilityLabel("Account: \(account)", unread: unread)
    }
}

/// The card's popover (290 wide): one row per account, then Add Account… and
/// Settings….
private struct SidebarAccountPopover: View {
    @Environment(AppEnvironment.self) private var environment
    let currentAccountID: Account.ID
    let dismiss: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(environment.accounts) { account in
                accountRow(account)
            }
            Rectangle()
                .fill(MailTheme.Color.lineSoft)
                .frame(height: 1)
                .padding(.vertical, MailTheme.Spacing.xs)
                .padding(.horizontal, MailTheme.Spacing.sm)
                .accessibilityHidden(true)
            SidebarPopoverItem(action: {
                dismiss()
                environment.presentsAddAccount = true
            }) {
                Text("Add Account…")
                    .textStyle(MailTheme.Typography.body)
                    .padding(.leading, Self.textInset)
                Spacer(minLength: 0)
            }
            .accessibilityIdentifier(AccessibilityID.Sidebar.addAccount)
            SidebarPopoverItem(action: {
                dismiss()
                environment.showSettings(.account, accountID: currentAccountID, open: openSettings)
            }) {
                Text("Settings…")
                    .textStyle(MailTheme.Typography.body)
                    .padding(.leading, Self.textInset)
                Spacer(minLength: 0)
                Text(SidebarPresentation.settingsShortcut)
                    .textStyle(MailTheme.Typography.meta)
                    .foregroundStyle(MailTheme.Color.ink3)
                    .accessibilityHidden(true)
            }
            .accessibilityHint("Opens Settings at this account")
            .accessibilityIdentifier(AccessibilityID.Sidebar.settings)
        }
        .padding(MailTheme.Spacing.xs)
        .frame(width: Self.width)
    }

    private func accountRow(_ account: Account) -> some View {
        let isCurrent = account.id == currentAccountID
        let unread = environment.unreadCount(forAccount: account.id)
        let host = account.origin.host ?? account.origin.absoluteString
        return SidebarPopoverItem(action: {
            dismiss()
            if !isCurrent { environment.selectedAccountID = account.id }
        }) {
            Image(systemName: MailTheme.Symbol.currentItem)
                .font(MailTheme.Typography.caption.font)
                .foregroundStyle(MailTheme.Color.ink)
                .opacity(isCurrent ? 1 : 0)
                .frame(width: Self.checkWidth)
                .accessibilityHidden(true)
            SettingsAccountAvatar(label: account.label, tint: environment.accountTint(for: account.id), diameter: Self.avatarDiameter)
            VStack(alignment: .leading, spacing: 0) {
                Text(account.label)
                    .textStyle(isCurrent ? MailTheme.Typography.headline : MailTheme.Typography.body)
                    .foregroundStyle(MailTheme.Color.ink)
                Text(host)
                    .textStyle(MailTheme.Typography.caption)
                    .foregroundStyle(MailTheme.Color.ink3)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if unread > 0 {
                Text("\(unread)")
                    .textStyle(MailTheme.Typography.metaStrong)
                    .foregroundStyle(MailTheme.Color.ink2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SidebarPresentation.accessibilityLabel("\(account.label), \(host)", unread: unread))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isCurrent ? "The account this window shows" : "Shows this account in the window")
        .accessibilityIdentifier(AccessibilityID.Sidebar.accountRowPrefix + account.id)
    }

    static let width: CGFloat = 290
    /// An account row's avatar — smaller than the card's own.
    static let avatarDiameter: CGFloat = 24
    /// The check column, so Add Account… and Settings… line up with the names
    /// (the mock's 30pt left inset = check column + gap).
    static let checkWidth: CGFloat = 14
    static let textInset = checkWidth + MailTheme.Spacing.sm
}

/// One popover row: a plain button with the menu-like hover fill.
private struct SidebarPopoverItem<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: MailTheme.Spacing.sm + MailTheme.Spacing.xxs) {
                content()
            }
            .padding(.horizontal, MailTheme.Spacing.sm)
            .padding(.vertical, MailTheme.Spacing.xs)
            .frame(maxWidth: .infinity, minHeight: MailTheme.hitTarget, alignment: .leading)
            .background(
                isHovered ? MailTheme.Color.lineSoft : .clear,
                in: RoundedRectangle(cornerRadius: MailTheme.Radius.sm)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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

    @ViewBuilder private var statusText: some View {
        let text = Text(MailViewModel.statusDescription(for: status, lastSyncedAt: lastSyncedAt))
        // Bold and the danger token: caption-sized red on the sidebar material
        // does not clear 4.5:1 at regular weight, and this is the only signal
        // that sync is broken.
        if isProblem {
            text.font(MailTheme.Typography.statusProblem).foregroundStyle(MailTheme.failure).lineLimit(1)
        } else {
            text.textStyle(MailTheme.Typography.caption).foregroundStyle(MailTheme.syncing).lineLimit(1)
        }
    }

    private var isProblem: Bool {
        switch status {
        case .failed, .needsReauth: true
        case .idle, .syncing: false
        }
    }
}
