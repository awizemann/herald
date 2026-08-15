import Foundation
import HeraldKit
import Testing
import WebKit
@testable import Herald

/// Containment of untrusted message HTML: what the reading pane is allowed to
/// navigate to, and what the wrapping document permits.
@Suite struct MessageRenderingSecurityTests {
    /// The old delegate returned `.allow` for everything that was not a clicked
    /// link, so an `<iframe>`, an auto-submitting `<form>`, a `<meta refresh>` and
    /// a redirect all reached the network from inside the pane. Each case here
    /// fails on that implementation.
    @Test func onlyOurOwnInitialLoadIsAllowed() {
        let remote = URL(string: "https://tracker.example.com/beacon")!

        // Ours: the about:blank main-frame load `loadHTMLString` performs.
        #expect(
            NavigationPolicy.decide(
                url: URL(string: "about:blank"), navigationType: .other,
                isMainFrame: true, isOurInitialLoad: true
            ) == .allow
        )
        // A second `.other` navigation is no longer ours.
        #expect(
            NavigationPolicy.decide(
                url: remote, navigationType: .other,
                isMainFrame: true, isOurInitialLoad: false
            ) == .cancel
        )
        // An iframe: `.other`, but not the main frame.
        #expect(
            NavigationPolicy.decide(
                url: remote, navigationType: .other,
                isMainFrame: false, isOurInitialLoad: true
            ) == .cancel
        )
        // A form post, and a meta-refresh/redirect.
        #expect(
            NavigationPolicy.decide(
                url: remote, navigationType: .formSubmitted,
                isMainFrame: true, isOurInitialLoad: true
            ) == .cancel
        )
        #expect(
            NavigationPolicy.decide(
                url: remote, navigationType: .formResubmitted,
                isMainFrame: true, isOurInitialLoad: true
            ) == .cancel
        )
        // Even flagged as ours, a non-about: URL is somebody else's document.
        #expect(
            NavigationPolicy.decide(
                url: remote, navigationType: .other,
                isMainFrame: true, isOurInitialLoad: true
            ) == .cancel
        )
    }

    /// Fails if a clicked link stops opening in the browser (dead links) or starts
    /// navigating in-pane, and if a hostile scheme is handed to NSWorkspace.
    @Test func clickedLinksLeaveThePaneAndOnlyForSafeSchemes() {
        func decide(_ raw: String) -> NavigationDecision {
            NavigationPolicy.decide(
                url: URL(string: raw), navigationType: .linkActivated,
                isMainFrame: true, isOurInitialLoad: false
            )
        }
        #expect(decide("https://example.com/thread") == .openExternally)
        #expect(decide("http://example.com/thread") == .openExternally)
        #expect(decide("mailto:ada@example.net") == .openExternally)
        #expect(decide("file:///etc/passwd") == .cancel)
        #expect(decide("javascript:alert(1)") == .cancel)
        #expect(decide("herald://oauth/callback") == .cancel)
        #expect(
            NavigationPolicy.decide(
                url: nil, navigationType: .linkActivated, isMainFrame: true, isOurInitialLoad: false
            ) == .cancel
        )
    }

    /// The wrapping document is the last line of defence if the rule list is ever
    /// absent. Fails if the CSP stops being emitted, if it lets remote images
    /// through before the user trusts the sender, or if framing/forms/base-uri are
    /// left open.
    @Test func wrappingDocumentCarriesALockedDownCSP() {
        let blocked = MailViewModel.document(wrapping: "<p>hi</p>")
        #expect(blocked.contains(#"http-equiv="Content-Security-Policy""#))
        let policy = MailViewModel.contentSecurityPolicy(allowsRemote: false)
        #expect(blocked.contains(policy))
        #expect(policy.contains("default-src 'none'"))
        #expect(policy.contains("img-src data: cid:"))
        #expect(!policy.contains("https:"), "Remote images must stay blocked until the sender is trusted")
        #expect(policy.contains("form-action 'none'"))
        #expect(policy.contains("frame-src 'none'"))
        #expect(policy.contains("base-uri 'none'"))
        // Plain-text bodies go through the same wrapper.
        #expect(MailViewModel.document(wrappingPlainText: "hi").contains("Content-Security-Policy"))

        // Only after an explicit trust does the image source widen — and only that.
        let trusted = MailViewModel.contentSecurityPolicy(allowsRemote: true)
        #expect(trusted.contains("img-src data: cid: https: http:"))
        #expect(trusted.contains("default-src 'none'"))
        #expect(trusted.contains("frame-src 'none'"))
    }

    /// `cid:` parts are substituted as `data:` URLs, which the web view renders
    /// with the MIME type the part claims. Fails if a part claiming `text/html`
    /// (or anything scriptable) can still be substituted into the body.
    @Test func onlyMediaPartsBecomeInlineDataURLs() {
        #expect(MailViewModel.isRenderableInlineMedia("image/png"))
        #expect(MailViewModel.isRenderableInlineMedia("IMAGE/JPEG"))
        #expect(MailViewModel.isRenderableInlineMedia("video/mp4"))
        #expect(MailViewModel.isRenderableInlineMedia("audio/mpeg"))
        #expect(MailViewModel.isRenderableInlineMedia("image/svg+xml; charset=utf-8"))
        #expect(!MailViewModel.isRenderableInlineMedia("text/html"))
        #expect(!MailViewModel.isRenderableInlineMedia("application/xhtml+xml"))
        #expect(!MailViewModel.isRenderableInlineMedia("application/octet-stream"))
        #expect(!MailViewModel.isRenderableInlineMedia(""))
        #expect(!MailViewModel.isRenderableInlineMedia("image/"))
    }
}
