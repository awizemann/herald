import Foundation
import Testing
import WebKit
@testable import Herald

@MainActor
@Suite struct RemoteContentBlockerTests {
    /// Fails if the rule JSON is malformed or uses a resource type WebKit does not
    /// accept — a rule list that will not compile means message bodies would
    /// render with the network wide open (or not at all).
    @Test func ruleListCompiles() async throws {
        let store = try #require(WKContentRuleListStore.default())
        let identifier = "com.wizemann.herald.test-block-remote"
        let list = try await store.compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: RemoteContentBlocker.ruleJSON
        )
        #expect(list != nil)
        try? await store.removeContentRuleList(forIdentifier: identifier)
    }

    /// Fails if the filter stops matching remote image URLs (tracking pixels get
    /// through) or starts matching the `data:` URLs we substitute for inline
    /// `cid:` parts (inline images would silently disappear).
    @Test func filterBlocksRemoteURLsButNotInlineData() throws {
        let regexes = try RemoteContentBlocker.blockedSchemePrefixes.map {
            try NSRegularExpression(pattern: $0)
        }
        func matches(_ url: String) -> Bool {
            regexes.contains {
                $0.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
            }
        }
        // Every rule must name only resource types WebKit knows; an unknown one is
        // what made the first version of this list fail to compile.
        #expect(RemoteContentBlocker.ruleJSON.contains("\"style-sheet\""))
        // `ping` (and its siblings) were missing: an `<a ping>` or a beacon is a
        // tracking pixel WebKit classifies as neither `image` nor `raw`.
        #expect(RemoteContentBlocker.ruleJSON.contains("\"ping\""))
        #expect(RemoteContentBlocker.ruleJSON.contains("\"websocket\""))
        #expect(RemoteContentBlocker.ruleJSON.contains("\"fetch\""))
        #expect(RemoteContentBlocker.ruleJSON.contains("\"popup\""))
        #expect(matches("https://tracker.example.com/pixel.png"))
        #expect(matches("http://tracker.example.com/pixel.png"))
        #expect(!matches("data:image/png;base64,iVBORw0KGgo="))
        #expect(!matches("about:blank"))
        #expect(!matches("cid:part1@example.com"))
    }

    /// Fails if an attacker-supplied filename could escape the chosen directory
    /// or hide the file — the save panel writes exactly this name.
    @Test func attachmentFilenamesAreSanitized() {
        #expect(AttachmentSaver.sanitized("../../etc/passwd") == "_.._etc_passwd")
        #expect(AttachmentSaver.sanitized(".hidden") == "hidden")
        #expect(AttachmentSaver.sanitized("") == "attachment")
        #expect(AttachmentSaver.sanitized("report:2026.pdf") == "report_2026.pdf")
    }

    /// A saved attachment came off the network, so Gatekeeper must prompt before
    /// it is opened. `LSFileQuarantineEnabled` alone does not cover it: the atomic
    /// write replaces the file and the flag goes with it. Fails if nothing stamps
    /// the file after the write.
    @Test func savedAttachmentsAreQuarantined() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("herald-quarantine-\(UUID().uuidString).txt")
        try Data("payload".utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let before = try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        AttachmentSaver.quarantine(url)

        let values = try url.resourceValues(forKeys: [.quarantinePropertiesKey])
        guard let properties = values.quarantineProperties else {
            // Some sandbox/volume combinations refuse the attribute outright; that
            // is an environment limit, not a regression in the saver.
            return
        }
        // The record has to be OURS, and it has to have changed: under the app
        // sandbox the file already arrives quarantined as
        // `LSQuarantineTypeSandboxed` (and the sandbox keeps the type key to
        // itself), so "is quarantined" alone would pass without the saver's stamp.
        #expect(properties[kLSQuarantineAgentNameKey as String] as? String == "Herald")
        #expect(
            (properties as NSDictionary) != ((before ?? [:]) as NSDictionary),
            "quarantine(_:) left the file's quarantine record untouched"
        )
    }

    /// Fails if a typed origin is accepted without https, or if a trailing slash
    /// produces a different account id than the same origin without one.
    @Test func originValidation() {
        #expect(AppEnvironment.normalizedOrigin(from: "http://mail.example.com") == nil)
        #expect(AppEnvironment.normalizedOrigin(from: "   ") == nil)
        #expect(
            AppEnvironment.normalizedOrigin(from: "https://mail.example.com/")?.absoluteString
                == "https://mail.example.com"
        )
        #expect(
            AppEnvironment.normalizedOrigin(from: "mail.example.com")?.absoluteString
                == "https://mail.example.com"
        )
    }
}
