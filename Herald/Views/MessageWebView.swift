import AppKit
import OSLog
import SwiftUI
import WebKit

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "MessageWebView")

/// Renders one message body.
///
/// The web view is a non-Sendable AppKit type and stays on the main actor.
/// JavaScript is disabled, the document is loaded with a nil base URL, and while
/// `blocksRemote` is set the compiled rule list stops every network load, so a
/// tracking pixel cannot fire before the user trusts the sender.
/// What the reading pane may do with a navigation it is asked about.
nonisolated enum NavigationDecision: Sendable, Hashable {
    /// The one navigation we perform ourselves: `loadHTMLString`'s own load.
    case allow
    /// Refuse outright — iframes, forms, meta refresh, redirects, subframes.
    case cancel
    /// A link the user clicked: hand it to the default browser and cancel here.
    case openExternally
}

/// The containment rule, extracted from the delegate so it can be tested
/// exhaustively without a live web view.
///
/// Message HTML is untrusted. The old rule allowed everything that was not a
/// `.linkActivated` link, which let an `<iframe>`, an auto-submitting `<form>`
/// and a `<meta http-equiv="refresh">` all reach the network from inside the
/// pane — the exact channels the remote-content blocker exists to close.
nonisolated enum NavigationPolicy {
    static func decide(
        url: URL?,
        navigationType: WKNavigationType,
        isMainFrame: Bool,
        isOurInitialLoad: Bool
    ) -> NavigationDecision {
        if navigationType == .linkActivated {
            guard let url, let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme)
            else { return .cancel }
            return .openExternally
        }
        // `loadHTMLString(_:baseURL: nil)` navigates the main frame to about:blank.
        // That, and only that, is ours.
        guard isOurInitialLoad, isMainFrame, navigationType == .other else { return .cancel }
        guard let url else { return .allow }
        return url.scheme?.lowercased() == "about" ? .allow : .cancel
    }
}

struct MessageWebView: NSViewRepresentable {
    let body: RenderedBody

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = preferences
        configuration.suppressesIncrementalRendering = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Link preview fetches the target URL to build the popover — a remote load
        // the rule list should not have to be the only thing standing in front of.
        webView.allowsLinkPreview = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.load(body, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(body, into: webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loaded: RenderedBody?
        private var loadTask: Task<Void, Never>?
        /// Set immediately before `loadHTMLString` and consumed by the first
        /// main-frame decision, so exactly one navigation per render is ours.
        private var expectsOurLoad = false
        /// Every decision this coordinator made, newest last. Test seam: "the
        /// iframe was cancelled" is only assertable if the decisions are recorded.
        private(set) var decisions: [NavigationDecision] = []

        /// Reloading identical content would flash the pane on every unrelated
        /// state change, so the last render is compared first.
        func load(_ body: RenderedBody, into webView: WKWebView) {
            guard loaded != body else { return }
            loaded = body
            loadTask?.cancel()
            loadTask = Task { [weak webView] in
                let ruleList = body.blocksRemote ? await RemoteContentBlocker.ruleList() : nil
                guard let webView, !Task.isCancelled else { return }
                webView.configuration.userContentController.removeAllContentRuleLists()
                if body.blocksRemote {
                    guard let ruleList else {
                        // Without the blocker we refuse to render remote-capable
                        // HTML rather than rendering it unprotected.
                        logger.error("Refusing to render: remote-content blocker unavailable")
                        self.expectsOurLoad = true
                        webView.loadHTMLString(Self.blockerFailureDocument, baseURL: nil)
                        return
                    }
                    webView.configuration.userContentController.add(ruleList)
                }
                self.expectsOurLoad = true
                webView.loadHTMLString(body.html, baseURL: nil)
            }
        }

        /// Links open in the user's browser; nothing else navigates at all.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            let url = navigationAction.request.url
            let decision = NavigationPolicy.decide(
                url: url,
                navigationType: navigationAction.navigationType,
                isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false,
                isOurInitialLoad: expectsOurLoad
            )
            decisions.append(decision)
            switch decision {
            case .allow:
                expectsOurLoad = false
                return .allow
            case .cancel:
                logger.warning(
                    "Blocked in-pane navigation (type \(navigationAction.navigationType.rawValue, privacy: .public), scheme \(url?.scheme ?? "none", privacy: .public))"
                )
                return .cancel
            case .openExternally:
                if let url { NSWorkspace.shared.open(url) }
                return .cancel
            }
        }

        private static let blockerFailureDocument = """
            <!doctype html><html><body style="font: -apple-system-body; margin:16px">
            <p>Herald could not start its content blocker, so this message was not displayed.</p>
            </body></html>
            """
    }
}
