import HeraldKit
import SwiftUI

// Settings' root pages: General, Notifications, Privacy (app-wide, "HERALD")
// and Account, Signatures (per account, "ACCOUNT"). Chrome in
// `SettingsChrome.swift`; the window and its sidebar in `SettingsView.swift`.

// MARK: - General

/// Settings › General: the list density, with a live preview of each option.
struct GeneralSettingsPage: View {
    @Environment(AppEnvironment.self) private var environment
    let breadcrumb: String
    @AppStorage private var density: ListDensity

    init(breadcrumb: String) {
        self.breadcrumb = breadcrumb
        _density = Self.densityStorage()
    }

    /// The one declaration of the density preference's storage: `list.density`
    /// (``ListDensity/storageKey``), Comfortable when unset. `store: nil` is the
    /// scene's `defaultAppStorage` (the UI-test harness swaps that suite in); a
    /// test hands a scratch suite to prove the key and the default.
    static func densityStorage(store: UserDefaults? = nil) -> AppStorage<ListDensity> {
        if let store {
            AppStorage(wrappedValue: .comfortable, ListDensity.storageKey, store: store)
        } else {
            AppStorage(wrappedValue: .comfortable, ListDensity.storageKey)
        }
    }

    var body: some View {
        SettingsPage(title: SettingsRoute.general.title, breadcrumb: breadcrumb) {
            SettingsSection(title: "Message list") {
                SettingsCard {
                    SettingsRow(
                        title: "Density",
                        note: "Row height and preview length in every list. Applies to all accounts.",
                        source: .herald
                    ) {
                        Picker("Density", selection: $density) {
                            ForEach(ListDensity.allCases, id: \.self) { option in
                                Text(Self.title(for: option)).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("Density")
                        .accessibilityIdentifier(AccessibilityID.Settings.density)
                    }
                    HStack(alignment: .top, spacing: MailTheme.Spacing.md) {
                        ForEach(ListDensity.allCases, id: \.self) { option in
                            DensityPreview(
                                density: option,
                                isChosen: option == density,
                                tint: previewTint,
                                choose: { density = option }
                            )
                        }
                    }
                    .padding(.top, MailTheme.Spacing.md + MailTheme.Spacing.xxs)
                    .padding([.horizontal, .bottom], MailTheme.Spacing.lg)
                }
            }
        }
    }

    static func title(for density: ListDensity) -> String {
        switch density {
        case .comfortable: "Comfortable"
        case .compact: "Compact"
        }
    }

    /// The badge wash in the preview follows the account in front, so the
    /// preview looks like that account's list.
    private var previewTint: MailTheme.AccountTint {
        environment.selectedAccountID.map { environment.accountTint(for: $0) } ?? MailTheme.accountTints[0]
    }
}

/// One density's preview: the same selected row at that density, framed; the
/// chosen one ringed in accent. Clicking it chooses it, like the segment.
private struct DensityPreview: View {
    let density: ListDensity
    let isChosen: Bool
    let tint: MailTheme.AccountTint
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MailTheme.Spacing.xs + MailTheme.Spacing.xxs) {
            Text(GeneralSettingsPage.title(for: density))
                .textStyle(MailTheme.Typography.caption)
                .foregroundStyle(MailTheme.Color.ink3)
            Button(action: choose) {
                row
                    .padding(MailTheme.Spacing.xs)
                    .background(MailTheme.Color.bg, in: RoundedRectangle(cornerRadius: MailTheme.Radius.md))
                    .overlay {
                        RoundedRectangle(cornerRadius: MailTheme.Radius.md)
                            .strokeBorder(
                                isChosen ? MailTheme.Color.accent : .clear,
                                lineWidth: SettingsLayout.previewRingWidth
                            )
                    }
                    .contentShape(RoundedRectangle(cornerRadius: MailTheme.Radius.md))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(GeneralSettingsPage.title(for: density)) preview")
            .accessibilityAddTraits(isChosen ? .isSelected : [])
            .accessibilityHint(isChosen ? "" : "Uses this density")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Sample content, drawn with the row's real type styles; a static picture
    // of a row, not the list's row view (R5 rebuilds that).
    private var row: some View {
        HStack(alignment: .top, spacing: MailTheme.Spacing.sm) {
            Circle()
                .fill(MailTheme.Color.accent)
                .frame(width: MailTheme.unreadDotDiameter, height: MailTheme.unreadDotDiameter)
                .padding(.top, MailTheme.Spacing.xs)
            if density == .comfortable {
                VStack(alignment: .leading, spacing: MailTheme.Spacing.xxs) {
                    HStack(spacing: MailTheme.Spacing.xs) {
                        badge
                        Text(Self.mailbox)
                            .textStyle(MailTheme.Typography.caption)
                            .foregroundStyle(MailTheme.Color.ink2)
                        Text(Self.sender).textStyle(MailTheme.Typography.headline)
                    }
                    Text(Self.subject).textStyle(MailTheme.Typography.headline)
                    Text(Self.snippet)
                        .textStyle(MailTheme.Typography.snippet)
                        .foregroundStyle(MailTheme.Color.ink2)
                        .lineLimit(2, reservesSpace: true)
                }
            } else {
                VStack(alignment: .leading, spacing: MailTheme.Spacing.xxs) {
                    HStack(spacing: MailTheme.Spacing.xs) {
                        badge
                        Text(Self.sender).textStyle(MailTheme.Typography.headline).layoutPriority(1)
                        Text(Self.subject)
                            .textStyle(MailTheme.Typography.body)
                            .foregroundStyle(MailTheme.Color.ink2)
                    }
                    Text(Self.snippet)
                        .textStyle(MailTheme.Typography.snippet)
                        .foregroundStyle(MailTheme.Color.ink2)
                }
            }
            Spacer(minLength: 0)
            Text(Self.time)
                .textStyle(MailTheme.Typography.meta)
                .foregroundStyle(MailTheme.Color.ink3)
        }
        .lineLimit(1)
        .foregroundStyle(MailTheme.Color.ink)
        .padding(.vertical, density == .comfortable ? MailTheme.Spacing.md + MailTheme.Spacing.xxs : MailTheme.Spacing.sm)
        .padding(.horizontal, MailTheme.Spacing.sm + MailTheme.Spacing.xxs)
        .background(
            MailTheme.Color.select,
            in: RoundedRectangle(cornerRadius: density == .comfortable ? MailTheme.Radius.md : MailTheme.Radius.sm)
        )
        .accessibilityHidden(true)
    }

    private var badge: some View {
        Text(Self.monogram)
            .font(MailTheme.Typography.tag.font)
            .padding(.horizontal, MailTheme.Spacing.xs)
            .frame(height: SettingsLayout.rowBadgeHeight)
            .background(tint.solid.opacity(MailTheme.Wash.badgeFill), in: RoundedRectangle(cornerRadius: MailTheme.Radius.badgeSmall))
            .overlay {
                RoundedRectangle(cornerRadius: MailTheme.Radius.badgeSmall)
                    .strokeBorder(tint.solid.opacity(MailTheme.Wash.badgeBorder), lineWidth: 1)
            }
    }

    private static let monogram = "AC"
    private static let mailbox = "sales@"
    private static let sender = "Mara Okafor"
    private static let subject = "Q4 retainer — revised scope"
    private static let snippet = "Attached is the revised scope for Q4. We’ve folded the brand audit into phase one."
    private static let time = "10:42"
}

// MARK: - Account

/// Settings › Account, for the account in front: its server and sync, its
/// colour on this Mac, and signing it out (moved here from the sidebar's
/// ellipsis menu).
struct AccountSettingsPage: View {
    @Environment(AppEnvironment.self) private var environment
    let account: Account
    let mail: MailViewModel
    let breadcrumb: String

    /// N1: sign-out revokes the OAuth grant, so "nothing changes on the server"
    /// (the handoff's line) would be untrue. The mail itself is untouched.
    static let signOutExplanation =
        "Removes this account and its cached mail from Herald on this Mac. "
            + "Other accounts keep syncing. Your mail on the server isn’t touched."

    var body: some View {
        SettingsPage(title: SettingsRoute.account.title, breadcrumb: breadcrumb) {
            SettingsSection(title: "Server") {
                SettingsCard {
                    SettingsRow(title: "Server", source: .server) {
                        Text(account.origin.absoluteString)
                            .textStyle(MailTheme.Typography.meta)
                            .foregroundStyle(MailTheme.Color.ink2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    // N2: the status only — the cadence is not a fixed fact
                    // (it stretches while the wake socket is up), so the
                    // handoff's "checks every 2 minutes" is left out.
                    SettingsRow(
                        title: "Sync",
                        note: MailViewModel.statusDescription(for: mail.status, lastSyncedAt: mail.lastSyncedAt)
                    ) {
                        Button("Sync Now") { Task { await mail.refresh() } }
                            .buttonStyle(SettingsOutlineButtonStyle())
                            .disabled(mail.status == .syncing)
                            .accessibilityIdentifier(AccessibilityID.Settings.syncNow)
                    }
                }
            }
            SettingsSection(title: "On this Mac") {
                SettingsCard {
                    SettingsRow(
                        title: "Account colour",
                        note: "Used for the avatar and every domain badge in this account.",
                        source: .herald
                    ) {
                        AccountTintPicker(accountID: account.id)
                    }
                }
            }
            SettingsCard {
                HStack(alignment: .center, spacing: MailTheme.Spacing.md) {
                    VStack(alignment: .leading, spacing: MailTheme.Spacing.xxs) {
                        Text("Sign out of \(account.label)")
                            .textStyle(MailTheme.Typography.headline)
                            .foregroundStyle(MailTheme.Color.ink)
                        Text(Self.signOutExplanation)
                            .textStyle(MailTheme.Typography.snippet)
                            .foregroundStyle(MailTheme.Color.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Sign Out…") { environment.requestSettingsSignOut(accountID: account.id) }
                        .buttonStyle(SettingsOutlineButtonStyle(isDestructive: true))
                        .accessibilityHint("Asks before signing out of \(account.label)")
                        .accessibilityIdentifier(AccessibilityID.Settings.signOut)
                }
                .padding(.vertical, MailTheme.Spacing.lg)
                .padding(.horizontal, MailTheme.Spacing.lg)
            }
        }
        .confirmationDialog(
            // The CAPTURED name: the prompt outlives the answer, so the title
            // never re-reads an emptied value while the dialog animates out.
            "Sign out of \(environment.settingsSignOutPrompt?.accountLabel ?? account.label)?",
            isPresented: Binding(
                get: { environment.isConfirmingSettingsSignOut },
                set: { if !$0 { environment.isConfirmingSettingsSignOut = false } }
            ),
            titleVisibility: .visible,
            presenting: environment.settingsSignOutPrompt
        ) { prompt in
            Button("Sign Out", role: .destructive) {
                Task { await environment.confirmSettingsSignOut(prompt) }
            }
            Button("Cancel", role: .cancel) { environment.cancelSettingsSignOut() }
        } message: { _ in
            Text(Self.signOutExplanation)
        }
    }
}

/// The eight tint swatches plus Reset. Writes go through ``AppEnvironment``,
/// which is what repaints every avatar drawn from the same tint.
private struct AccountTintPicker: View {
    @Environment(AppEnvironment.self) private var environment
    let accountID: Account.ID

    var body: some View {
        let current = environment.accountTintName(for: accountID)
        HStack(spacing: 0) {
            ForEach(MailTheme.accountTints) { tint in
                let isCurrent = tint.name == current
                Button {
                    environment.setAccountTint(tint.name, for: accountID)
                } label: {
                    Circle()
                        .fill(tint.solid)
                        .frame(width: SettingsLayout.swatchDiameter, height: SettingsLayout.swatchDiameter)
                        .padding(SettingsLayout.swatchGap)
                        .overlay {
                            Circle().strokeBorder(
                                isCurrent ? MailTheme.Color.ink : .clear,
                                lineWidth: SettingsLayout.swatchRingWidth
                            )
                        }
                        // Drawn at 18pt, hit at 28.
                        .frame(width: MailTheme.hitTarget, height: MailTheme.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tint.displayName)
                .accessibilityLabel(tint.displayName)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .accessibilityIdentifier(AccessibilityID.Settings.tintSwatchPrefix + tint.name)
            }
            // No foreground override: a fixed colour would hide the dimming
            // that says Reset is unavailable until a colour has been picked.
            Button("Reset") { environment.setAccountTint(nil, for: accountID) }
                .buttonStyle(.borderless)
                .padding(.leading, MailTheme.Spacing.sm)
                .disabled(!environment.hasAccountTintOverride(accountID))
                .help("Go back to this account’s automatic colour")
                .accessibilityLabel("Reset account colour")
                .accessibilityIdentifier(AccessibilityID.Settings.tintReset)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Account colour")
    }
}

// MARK: - Signatures

/// Settings › Signatures — the existing pane, moved in unchanged. The pane is a
/// grouped `Form` that scrolls itself, so the page frame does not scroll.
struct SignaturesSettingsPage: View {
    @Environment(AppEnvironment.self) private var environment
    let breadcrumb: String

    var body: some View {
        SettingsPage(title: SettingsRoute.signatures.title, breadcrumb: breadcrumb, scrolls: false) {
            // `AppEnvironment` caches one model per account, so switching
            // accounts hands the pane a DIFFERENT object and the pane keys its
            // load on that identity — no `.id(…)` reset (it would tear the
            // subtree down, open editor sheet and all).
            if let model = environment.signatureSettingsModel() {
                SignatureSettingsPane(
                    model: model,
                    reauthenticate: { environment.reauthenticateSelectedAccount() }
                )
                // Takes the page's remaining height and no more. The pane
                // grew up inside a fixed-size TabView and reports a minimum
                // height taller than this window, which pushed the page's
                // title (and the sidebar with it) out of view.
                .frame(minHeight: 0, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: MailTheme.Radius.lg))
                .overlay {
                    RoundedRectangle(cornerRadius: MailTheme.Radius.lg)
                        .strokeBorder(MailTheme.Color.line, lineWidth: 1)
                }
            }
        }
    }
}

// MARK: - Notifications

/// The two alert switches. Both write straight to `UserDefaults` under the keys
/// ``NotificationSettings`` owns, which is what the sync path and the Dock badge
/// read — no copy of the value lives anywhere else.
struct NotificationSettingsPane: View {
    let environment: AppEnvironment
    let breadcrumb: String

    @AppStorage(NotificationSettings.newMailKey) private var newMailEnabled = true
    @AppStorage(NotificationSettings.dockBadgeKey) private var dockBadgeEnabled = true

    var body: some View {
        SettingsPage(title: SettingsRoute.notifications.title, breadcrumb: breadcrumb) {
            SettingsCard {
                SettingsRow(
                    title: "Notify me about new mail",
                    note: "Banners appear only while Herald is in the background. macOS decides whether they are shown at all — allow them in System Settings › Notifications."
                ) {
                    Toggle("Notify me about new mail", isOn: $newMailEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: newMailEnabled) { _, enabled in
                            // Permission is asked for HERE, when the user opts
                            // in — not at launch, and not at the first arrival.
                            Task { await environment.notificationsSettingChanged(enabled: enabled) }
                        }
                }
                SettingsRow(title: "Show unread count on the Dock icon") {
                    Toggle("Show unread count on the Dock icon", isOn: $dockBadgeEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: dockBadgeEnabled) { _, _ in
                            environment.applyDockBadge()
                        }
                }
            }
        }
    }
}

// MARK: - Privacy

/// The usage-analytics opt-out. There is no `@AppStorage` mirror on purpose: the
/// swift-stats SDK persists the choice and is the only reader of it, so a second
/// copy in `UserDefaults` could only ever disagree with the truth.
///
/// Toggling it records NO usage event — an opt-out must not itself be reported.
struct PrivacySettingsPane: View {
    /// The seam. The model is built FROM it, once, rather than handed in: a model
    /// constructed in the parent's `body` is reallocated on every pass and all
    /// but the first copy is thrown away by `@State`.
    ///
    /// TODO: this model belongs in `AppEnvironment`, beside
    /// `signatureSettingsModel()`, so it outlives the Settings window the way
    /// the per-account models do.
    let usage: any UsageTracking
    let breadcrumb: String
    /// `nil` until the first `.task`. That is not a gap in the UI: an unread
    /// snapshot is exactly the `isEnabled == nil` state the switch already draws
    /// as inert-and-loading, so there is nothing to show differently.
    @State private var model: UsagePrivacyModel?

    var body: some View {
        SettingsPage(title: SettingsRoute.privacy.title, breadcrumb: breadcrumb) {
            SettingsCard {
                SettingsRow(
                    title: "Share anonymous usage",
                    note: Self.explanation(isAvailable: usage.isAvailable)
                ) {
                    Toggle("Share anonymous usage", isOn: Binding(
                        get: { model?.isEnabled ?? false },
                        set: { enabled in Task { await model?.setEnabled(enabled) } }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    // Until the snapshot has been read there is nothing truthful
                    // to show, so the switch is inert rather than guessing a
                    // position. Likewise inert when this build has no tracker
                    // at all — flipping it would silently do nothing.
                    .disabled(model?.isEnabled == nil || !usage.isAvailable)
                    // While loading or unavailable, the hint says why the switch
                    // is inert. Once loaded and available there is NO hint: the
                    // explanation is a sibling element VoiceOver reads in its
                    // own right, and repeating it reads the paragraph twice.
                    .accessibilityHint(Self.accessibilityHint(
                        isEnabled: model?.isEnabled, isAvailable: usage.isAvailable
                    ))
                }
                if let confirmation = model?.confirmation {
                    Text(confirmation)
                        .textStyle(MailTheme.Typography.caption)
                        .foregroundStyle(MailTheme.Color.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, MailTheme.Spacing.sm)
                        .padding(.horizontal, MailTheme.Spacing.lg)
                }
            }
        }
        .task {
            // Built here, not in the parent's body, and kept across passes.
            let model = model ?? UsagePrivacyModel(usage: usage)
            self.model = model
            await model.load()
        }
    }

    /// The switch's VoiceOver hint. While the tracker's answer is still on its
    /// way, or when this build has no tracker to toggle, the disabled switch
    /// would otherwise be unexplained; once loaded and available the hint is
    /// empty, because the visible explanation is its own element and a hint
    /// repeating it makes VoiceOver read the paragraph twice.
    static func accessibilityHint(isEnabled: Bool?, isAvailable: Bool) -> String {
        guard isAvailable else { return "Usage analytics aren't included in this build" }
        return isEnabled == nil ? "Loading current setting" : ""
    }

    /// Verbatim from the approved plan's "Opt-out copy". Every clause of the
    /// "never sent" list is enforced by the privacy contract in `UsageEvent.swift`.
    /// Swapped out entirely — not appended to — when this build has no tracker:
    /// the privacy promises below are moot if nothing can be sent either way.
    static func explanation(isAvailable: Bool) -> String {
        guard isAvailable else { return unavailableExplanation }
        return """
            Sends which features you use (e.g. “archived a message”, “opened search”) and basic \
            app/OS version info to Herald’s developer, tagged with a random per-install identifier \
            so active installs can be counted. Never sent: your mail, subjects, addresses, search \
            text, mailbox names, account details, file names, or anything you type. Turn this off \
            and nothing further is sent, including anything queued.
            """
    }

    static let unavailableExplanation = "Usage analytics aren’t included in this build."
}

/// The toggle's whole behaviour, out of the view so it can be tested.
///
/// `isEnabled` is an optional because the SDK offers a snapshot and no change
/// stream: nil means "not read yet". Every write re-reads the tracker instead of
/// trusting the value it just sent, so the switch always shows the SDK's truth.
@MainActor
@Observable
final class UsagePrivacyModel {
    private let usage: any UsageTracking
    private(set) var isEnabled: Bool?
    /// A brief, unobtrusive confirmation shown after a successful write in a
    /// build where the tracker is actually available — there is no change
    /// notification from the SDK otherwise, so this is the only feedback a
    /// keyed build gives that the toggle did something. `nil` the rest of the
    /// time, including always in an unavailable build.
    private(set) var confirmation: String?

    /// `false` on a build with no usable write key — the seam's
    /// ``UsageTracking/isAvailable``, mirrored here so the view never talks to
    /// `usage` directly.
    var isAvailable: Bool { usage.isAvailable }

    init(usage: any UsageTracking) {
        self.usage = usage
    }

    func load() async {
        isEnabled = await usage.isEnabled
    }

    func setEnabled(_ enabled: Bool) async {
        await usage.setEnabled(enabled)
        await load()
        confirmation = isAvailable
            ? (enabled ? "Saved." : "Analytics are off — nothing is sent.")
            : nil
    }
}
