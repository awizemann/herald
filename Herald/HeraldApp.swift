import SwiftUI

@main
struct HeraldApp: App {
    /// Built here, but it does no work until `RootView`'s `.task` starts it —
    /// `App.init` must never open a store or touch the Keychain.
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .presentsComposeWindows(environment)
        }
        .defaultSize(width: 1180, height: 720)
        .commands { MailCommands(environment: environment) }

        ComposeScene(environment: environment)
    }
}
