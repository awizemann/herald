#if DEBUG
import SwiftUI

/// The "UI Test Controls" menu. Exists only when ``UITestHarness/launched`` is
/// non-nil — ``HeraldApp`` adds it inside `#if DEBUG` and `if let` — so neither
/// a Release build nor a normal Debug launch has it.
///
/// Every item carries an accessibility identifier with the `uitest.` prefix;
/// the titles are stable too, for queries that go by title.
struct UITestCommands: Commands {
    let harness: UITestHarness

    var body: some Commands {
        CommandMenu("UI Test Controls") {
            Section("Server") {
                ForEach(FakeHQBaseState.allCases, id: \.self) { state in
                    Button("Server: \(state.rawValue)") { harness.setServerState(state) }
                        .accessibilityIdentifier("uitest.server.\(state.rawValue)")
                }
            }
            Section("Sync poll") {
                Button("Sync poll: pause") { harness.setSyncPollPaused(true) }
                    .accessibilityIdentifier("uitest.poll.pause")
                Button("Sync poll: resume") { harness.setSyncPollPaused(false) }
                    .accessibilityIdentifier("uitest.poll.resume")
            }
            Section("Sign-in window") {
                presenterButton(.succeed)
                presenterButton(.hangUntilCancelled)
                presenterButton(.fail(SignInPresenterMode.defaultFailureReason))
                presenterButton(.userCancel)
                Button("Sign-in: complete pending") { harness.completePendingSignIns() }
                    .accessibilityIdentifier("uitest.presenter.completePending")
            }
            Section("Account store") {
                Button("Account store: refuse account list") { harness.setAccountStoreRefusesList(true) }
                    .accessibilityIdentifier("uitest.store.refuseList")
                Button("Account store: healthy") { harness.setAccountStoreRefusesList(false) }
                    .accessibilityIdentifier("uitest.store.healthy")
            }
            Section("Account activation") {
                Button("Activation: refuse") { harness.setActivationRefused(true) }
                    .accessibilityIdentifier("uitest.activation.refuse")
                Button("Activation: healthy") { harness.setActivationRefused(false) }
                    .accessibilityIdentifier("uitest.activation.healthy")
            }
            Divider()
            Button("Reset counters") { harness.resetCounters() }
                .accessibilityIdentifier("uitest.resetCounters")
        }
    }

    private func presenterButton(_ mode: SignInPresenterMode) -> some View {
        Button("Sign-in: \(mode.name)") { harness.setPresenterMode(mode) }
            .accessibilityIdentifier("uitest.presenter.\(mode.name)")
    }
}

/// The harness's live state, on screen in test mode only: the accessibility
/// VALUE of the element `uitest.status` is ``UITestHarness/status``
/// (`server=… presenter=… sends=N …`). Tiny and click-through, so it never
/// covers a control a test needs.
struct UITestStatusLabel: View {
    let harness: UITestHarness

    var body: some View {
        Text(harness.status)
            .font(MailTheme.Typography.meta.font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(MailTheme.Spacing.xxs)
            .allowsHitTesting(false)
            // A plain `Text` stays an XCUI StaticText whose VALUE is its text.
            // Wrapping it (`.accessibilityElement(children: .ignore)` + a
            // label) turned it into an "Other" element whose value XCUITest on
            // macOS reads back as empty — the status then never parsed.
            .accessibilityIdentifier("uitest.status")
    }
}
#endif
