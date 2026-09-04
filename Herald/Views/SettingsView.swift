import HeraldKit
import SwiftUI

/// ⌘, — the app's only preferences window, kept as a `Form`/`.formStyle(.grouped)`
/// so it is a stock macOS settings window rather than a hand-drawn one.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        TabView {
            NotificationSettingsPane(environment: environment)
                .tabItem { Label("Notifications", systemImage: "bell") }
            MailboxSettingsPane(model: environment.mail)
                .tabItem { Label("Mailboxes", systemImage: "tray.2") }
            PrivacySettingsPane(model: UsagePrivacyModel(usage: environment.usage))
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 640, height: 320)
    }
}

/// The usage-analytics opt-out. There is no `@AppStorage` mirror on purpose: the
/// swift-stats SDK persists the choice and is the only reader of it, so a second
/// copy in `UserDefaults` could only ever disagree with the truth.
///
/// Toggling it records NO usage event — an opt-out must not itself be reported.
struct PrivacySettingsPane: View {
    @State var model: UsagePrivacyModel

    var body: some View {
        Form {
            Section {
                Toggle("Share anonymous usage", isOn: Binding(
                    get: { model.isEnabled ?? false },
                    set: { enabled in Task { await model.setEnabled(enabled) } }
                ))
                // Until the snapshot has been read there is nothing truthful to
                // show, so the switch is inert rather than guessing a position.
                // Likewise inert when this build has no tracker at all — flipping
                // it would silently do nothing, which is the exact bug this fixes.
                .disabled(model.isEnabled == nil || !model.isAvailable)
                // While loading or unavailable, the hint says why the switch is
                // inert. Once loaded and available there is NO hint: the
                // explanation below is a sibling element VoiceOver reads in its
                // own right, and repeating it as the switch's hint reads the
                // whole paragraph twice.
                .accessibilityHint(Self.accessibilityHint(
                    isEnabled: model.isEnabled, isAvailable: model.isAvailable
                ))

                Text(Self.explanation(isAvailable: model.isAvailable))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let confirmation = model.confirmation {
                    Text(confirmation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, MailTheme.Spacing.xxs)
        .task { await model.load() }
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

/// The two alert switches. Both write straight to `UserDefaults` under the keys
/// ``NotificationSettings`` owns, which is what the sync path and the Dock badge
/// read — no copy of the value lives anywhere else.
struct NotificationSettingsPane: View {
    let environment: AppEnvironment

    @AppStorage(NotificationSettings.newMailKey) private var newMailEnabled = true
    @AppStorage(NotificationSettings.dockBadgeKey) private var dockBadgeEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Notify me about new mail", isOn: $newMailEnabled)
                    .onChange(of: newMailEnabled) { _, enabled in
                        // Permission is asked for HERE, when the user opts in —
                        // not at launch, and not at the first arrival.
                        Task { await environment.notificationsSettingChanged(enabled: enabled) }
                    }
                Text("Banners appear only while Herald is in the background. macOS decides whether they are shown at all — allow them in System Settings › Notifications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show unread count on the Dock icon", isOn: $dockBadgeEnabled)
                    .onChange(of: dockBadgeEnabled) { _, _ in
                        environment.applyDockBadge()
                    }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, MailTheme.Spacing.xxs)
    }
}

/// Per-mailbox chip colour. Changes write straight through the view-model, which
/// both persists them and is observed by the open conversation list — so the rows
/// repaint while this window is still up.
struct MailboxSettingsPane: View {
    let model: MailViewModel?

    var body: some View {
        Form {
            if let model, model.mailboxes.isEmpty == false {
                ForEach(model.mailboxes) { mailbox in
                    MailboxColorRow(model: model, mailbox: mailbox)
                }
            } else {
                // Not an error: Settings can be opened before an account is
                // restored, and an empty Form reads as a broken pane.
                Text("Mailboxes appear here once an account is signed in.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MailboxColorRow: View {
    let model: MailViewModel
    let mailbox: Mailbox

    var body: some View {
        // One line per mailbox: name + address on the left, colour + reset on the
        // right. An explicit HStack rather than LabeledContent — in a grouped Form
        // LabeledContent stacks its label over its content once the row is tight,
        // which is exactly the wrap the owner asked to remove.
        HStack(alignment: .center, spacing: MailTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: MailTheme.Spacing.xxs) {
                Text(name)
                Text(mailbox.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: MailTheme.Spacing.sm) {
                Picker("Color", selection: selectedToken) {
                    ForEach(MailTheme.mailboxPalette) { tint in
                        // The swatch is decorative; the row's name is what
                        // VoiceOver and Voice Control actually get.
                        Label {
                            Text(tint.displayName)
                        } icon: {
                            Circle().fill(tint.color)
                        }
                        .accessibilityLabel(tint.displayName)
                        .tag(tint.name)
                    }
                }
                .labelsHidden()
                .frame(width: 140)

                Button("Reset to Default") {
                    model.setMailboxColorToken(nil, for: mailbox.id)
                }
                .disabled(model.hasMailboxColorOverride(mailbox.id) == false)
            }
            .fixedSize()
        }
        .padding(.vertical, MailTheme.Spacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name), \(mailbox.address)")
    }

    private var name: String {
        mailbox.displayName.isEmpty ? mailbox.address : mailbox.displayName
    }

    /// Reads the RESOLVED token (override or default) so the popup always shows
    /// what the chip is actually drawn in, and writing one records an override.
    private var selectedToken: Binding<String> {
        Binding(
            get: { model.mailboxColorToken(for: mailbox.id) ?? MailTheme.mailboxPalette[0].name },
            set: { model.setMailboxColorToken($0, for: mailbox.id) }
        )
    }
}
