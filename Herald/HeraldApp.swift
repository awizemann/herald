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
    @State private var environment = AppEnvironment(
        usage: UsageAnalytics.makeTracker(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments,
            writeKey: UsageAnalytics.writeKey(from: .main)
        )
    )

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .presentsComposeWindows(environment)
        }
        .defaultSize(width: 1180, height: 720)
        .commands { MailCommands(environment: environment) }

        ComposeScene(environment: environment)

        // Gives Herald ⌘, and the standard Settings window chrome for free.
        Settings {
            SettingsView()
                .environment(environment)
        }
    }
}
