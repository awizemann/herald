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
                        webView.loadHTMLString(Self.blockerFailureDocument, baseURL: nil)
                        return
                    }
                    webView.configuration.userContentController.add(ruleList)
                }
                webView.loadHTMLString(body.html, baseURL: nil)
            }
        }

        /// Links open in the user's browser; nothing navigates inside the pane.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url
            else { return .allow }
            guard let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme)
            else {
                logger.warning("Blocked link with scheme \(url.scheme ?? "none", privacy: .public)")
                return .cancel
            }
            NSWorkspace.shared.open(url)
            return .cancel
        }

        private static let blockerFailureDocument = """
            <!doctype html><html><body style="font: -apple-system-body; margin:16px">
            <p>Herald could not start its content blocker, so this message was not displayed.</p>
            </body></html>
            """
    }
}
