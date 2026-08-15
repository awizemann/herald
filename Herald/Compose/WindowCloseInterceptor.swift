import AppKit
import SwiftUI

/// Routes the window's red close button through the composer's own close rule.
///
/// ⌘W already went through ``ComposeViewModel/requestClose()``, but clicking the
/// title-bar button did not: AppKit closed the window, `onDisappear` cancelled
/// the pending autosave, and everything typed since the last save was gone with
/// no prompt. This puts the same rule in front of both.
struct WindowCloseInterceptor: NSViewRepresentable {
    /// Returns `true` when the window may close. A `false` answer is expected to
    /// have started whatever the composer wants to ask the user instead.
    let shouldClose: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(shouldClose: shouldClose) }

    func makeNSView(context: Context) -> NSView {
        let view = WindowObservingView()
        view.onWindowChange = { [coordinator = context.coordinator] window in
            coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.shouldClose = shouldClose
        context.coordinator.attach(to: nsView.window)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// The window delegate. SwiftUI installs its own delegate on the scene's
    /// window, so this one forwards everything it does not implement rather than
    /// replacing it — dropping those callbacks breaks the scene's own bookkeeping.
    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var shouldClose: () -> Bool
        private weak var window: NSWindow?
        /// The delegate this one displaced. `nonisolated(unsafe)` because the two
        /// `NSObject` overrides below are `nonisolated` (they override nonisolated
        /// declarations) and must read it; AppKit only ever sends delegate
        /// messages on the main thread, and only `attach`/`detach` — both
        /// main-actor — write it.
        private nonisolated(unsafe) weak var previous: NSWindowDelegate?

        init(shouldClose: @escaping () -> Bool) {
            self.shouldClose = shouldClose
        }

        func attach(to window: NSWindow?) {
            guard let window, window.delegate !== self else { return }
            self.window = window
            previous = window.delegate
            window.delegate = self
        }

        func detach() {
            guard window?.delegate === self else { return }
            window?.delegate = previous
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool { shouldClose() }

        nonisolated override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            return previous?.responds(to: aSelector) ?? false
        }

        nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? { previous }
    }
}

/// An invisible view that reports the window it lands in. `makeNSView` runs
/// before the view has a window, so the moment has to be observed, not sampled.
private final class WindowObservingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
