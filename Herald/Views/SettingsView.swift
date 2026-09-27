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
            // `AppEnvironment` already caches one model per account, so switching
            // accounts hands this pane a DIFFERENT object and the pane keys its
            // load on that object's identity. No `.id(selectedAccountID)`: an
            // id-reset tears the whole subtree down synchronously (and would
            // discard an open editor sheet) to achieve what passing identity as
            // an input achieves without it.
            if let signatures = environment.signatureSettingsModel() {
                SignatureSettingsPane(
                    model: signatures,
                    reauthenticate: { environment.reauthenticateSelectedAccount() }
                )
                .tabItem { Label("Signatures", systemImage: "signature") }
            }
            // The SEAM, not a model: the pane builds its model once, in `.task`.
            // Passing `UsagePrivacyModel(usage:)` here allocated a fresh one on
            // every body pass, all but the first immediately discarded by `@State`.
            //
            // TODO: this model belongs in `AppEnvironment`, beside
            // `signatureSettingsModel()`, so it outlives the Settings window the
            // way the per-account models do. Left here because `AppEnvironment`
            // is being split under another task; see the F2 report.
            PrivacySettingsPane(usage: environment.usage)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        // Taller than the three original panes needed: the Signatures list is a
        // scrolling Form with per-scope sections, and 320pt showed barely a row.
        .frame(width: 640, height: 420)
    }
}

/// The usage-analytics opt-out. There is no `@AppStorage` mirror on purpose: the
/// swift-stats SDK persists the choice and is the only reader of it, so a second
/// copy in `UserDefaults` could only ever disagree with the truth.
///
/// Toggling it records NO usage event — an opt-out must not itself be reported.
struct PrivacySettingsPane: View {
    /// The seam. The model is built FROM it, once, rather than handed in: a model
    /// constructed in the parent's `body` is reallocated on every pass and all
    /// but the first copy is thrown away by `@State`.
    let usage: any UsageTracking
    /// `nil` until the first `.task`. That is not a gap in the UI: an unread
    /// snapshot is exactly the `isEnabled == nil` state the switch already draws
    /// as inert-and-loading, so there is nothing to show differently.
    @State private var model: UsagePrivacyModel?

    var body: some View {
        Form {
            Section {
                Toggle("Share anonymous usage", isOn: Binding(
                    get: { model?.isEnabled ?? false },
                    set: { enabled in Task { await model?.setEnabled(enabled) } }
                ))
                // Until the snapshot has been read there is nothing truthful to
                // show, so the switch is inert rather than guessing a position.
                // Likewise inert when this build has no tracker at all — flipping
                // it would silently do nothing, which is the exact bug this fixes.
                .disabled(model?.isEnabled == nil || !usage.isAvailable)
                // While loading or unavailable, the hint says why the switch is
                // inert. Once loaded and available there is NO hint: the
                // explanation below is a sibling element VoiceOver reads in its
                // own right, and repeating it as the switch's hint reads the
                // whole paragraph twice.
                .accessibilityHint(Self.accessibilityHint(
                    isEnabled: model?.isEnabled, isAvailable: usage.isAvailable
                ))

                Text(Self.explanation(isAvailable: usage.isAvailable))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let confirmation = model?.confirmation {
                    Text(confirmation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, MailTheme.Spacing.xxs)
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
