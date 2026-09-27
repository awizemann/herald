import SwiftUI

@main
struct HeraldApp: App {
    /// Built here, but it does no work until `RootView`'s `.task` starts it —
    /// `App.init` must never open a store or touch the Keychain.
    ///
    /// The tracker is built here too, and that is safe: `StatsClient.init`
    /// performs no I/O (its queue path and defaults suite are resolved lazily
    /// inside the actor on first use), and under tests or without a write key
    /// `makeTracker` hands back a `NoopUsageTracker` that constructs nothing.
    @State private var environment = HeraldApp.makeEnvironment()

    /// The composition root's one branch. A Debug build launched with
    /// `-HeraldUITest <scenario>` takes the UI-test harness's all-fake
    /// environment (see `Herald/UITestSupport/`); every other launch — and every
    /// Release build, which contains no harness at all — builds the real one.
    static func makeEnvironment() -> AppEnvironment {
        #if DEBUG
        if let harness = UITestHarness.launched { return harness.environment }
        #endif
        return AppEnvironment(
            usage: UsageAnalytics.makeTracker(
                environment: ProcessInfo.processInfo.environment,
                arguments: ProcessInfo.processInfo.arguments,
                writeKey: UsageAnalytics.writeKey(from: .main)
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .presentsComposeWindows(environment)
                #if DEBUG
                .defaultAppStorage(UITestHarness.launched?.defaults ?? .standard)
                .overlay(alignment: .bottomLeading) {
                    if let harness = UITestHarness.launched { UITestStatusLabel(harness: harness) }
                }
                #endif
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            MailCommands(environment: environment)
            #if DEBUG
            if let harness = UITestHarness.launched { UITestCommands(harness: harness) }
            #endif
        }

        ComposeScene(environment: environment)

        // Gives Herald ⌘, and the standard Settings window chrome for free.
        Settings {
            SettingsView()
                .environment(environment)
                #if DEBUG
                .defaultAppStorage(UITestHarness.launched?.defaults ?? .standard)
                #endif
        }
        // The split layout wants room (sidebar 240 + a 720 page column); the
        // window opens at the handoff's size and never shrinks below the
        // view's minimum.
        .defaultSize(SettingsLayout.defaultSize)
        .windowResizability(.contentMinSize)
    }
}
