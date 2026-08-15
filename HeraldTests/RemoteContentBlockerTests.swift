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
