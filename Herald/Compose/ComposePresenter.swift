import SwiftUI

/// Watches the mail view-model's ``ComposeRequest`` slot and opens a compose
/// window for each one.
///
/// It lives on the main window rather than in `RootView` so the mail UI stays
/// unaware of windows: ⌘R only sets a request.
private struct ComposePresenter: ViewModifier {
    let environment: AppEnvironment
    @SwiftUI.Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: environment.mail?.composeRequest) { _, request in
            guard let request else { return }
            // Clear immediately so the same kind of request can be made again.
            environment.mail?.composeRequest = nil
            Task {
                guard let id = await environment.prepareCompose(request) else { return }
                openWindow(value: id)
            }
        }
    }
}

extension View {
    func presentsComposeWindows(_ environment: AppEnvironment) -> some View {
        modifier(ComposePresenter(environment: environment))
    }
}
