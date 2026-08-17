import Foundation
import OSLog
import WebKit

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "RemoteContent")

/// Compiles (once per launch) the `WKContentRuleList` that stops message HTML from
/// reaching the network.
///
/// Message HTML is untrusted: JavaScript is off, the body is loaded with a nil base
/// URL, and this rule list blocks every remote scheme so tracking pixels cannot
/// phone home before the user chooses to trust the sender.
enum RemoteContentBlocker {
    static let identifier = "com.wizemann.herald.block-remote"

    /// Blocks anything with a network scheme.
    ///
    /// WebKit's `url-filter` accepts only a restricted regex dialect — alternation
    /// groups are rejected at compile time — so the schemes are separate rules
    /// with plain prefix filters. `data:` and `about:` URLs (the inline images we
    /// substitute ourselves) match none of them.
    nonisolated static let blockedSchemePrefixes = ["^http", "^ws", "^ftp"]

    /// `ping`, `websocket`, `fetch` and `popup` were missing: an `<a ping>`, a
    /// beacon or a WebSocket is a perfectly serviceable tracking pixel, and none
    /// of them are classified as `image` or `raw`.
    nonisolated static let resourceTypes = [
        "image", "media", "font", "script", "style-sheet", "raw", "document", "svg-document",
        "ping", "popup", "websocket", "fetch",
    ]

    nonisolated static var ruleJSON: String {
        let rules = blockedSchemePrefixes.map { prefix in
            """
            {"trigger":{"url-filter":"\(prefix)","resource-type":[\(resourceTypes.map { "\"\($0)\"" }.joined(separator: ","))]},"action":{"type":"block"}}
            """
        }
        return "[\(rules.joined(separator: ","))]"
    }

    private static var compilation: Task<WKContentRuleList?, Never>?

    /// `nil` means compilation failed; the caller then refuses to render remote
    /// content at all rather than rendering it unprotected.
    static func ruleList() async -> WKContentRuleList? {
        if let compilation { return await compilation.value }
        let task = Task<WKContentRuleList?, Never> {
            do {
                return try await WKContentRuleListStore.default()?.compileContentRuleList(
                    forIdentifier: identifier,
                    encodedContentRuleList: ruleJSON
                )
            } catch {
                logger.error("Remote-content rule list failed to compile: \(error.localizedDescription, privacy: .private)")
                return nil
            }
        }
        compilation = task
        return await task.value
    }
}
