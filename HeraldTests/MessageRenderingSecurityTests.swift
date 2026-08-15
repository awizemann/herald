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

    /// The reading pane is a web area, and VoiceOver names it from the document's
    /// own `<title>`; without one it announces "HTML content" and the user cannot
    /// tell which message they are in. Fails if the title or `lang` is dropped —
    /// and, the title being sender-controlled text, if it is not escaped.
    @Test func theWrappingDocumentIsNamedAndLanguageTagged() {
        let titled = MailViewModel.document(wrapping: "<p>hi</p>", title: "Invoice question")
        #expect(titled.contains("<title>Invoice question</title>"))
        #expect(titled.contains("<html lang="))

        // A subject is untrusted text: it must not be able to close the tag.
        let hostile = MailViewModel.document(wrapping: "<p>hi</p>", title: "</title><script>x</script>")
        #expect(!hostile.contains("<script>"))
        #expect(hostile.contains("&lt;/title&gt;"))

        // An empty subject still names the area rather than leaving it untitled.
        #expect(MailViewModel.document(wrapping: "", title: "  ").contains("<title>Message</title>"))
        #expect(MailViewModel.document(wrappingPlainText: "hi", title: "Notes").contains("<title>Notes</title>"))
    }

    /// `updateNSView` runs on every pass through the reading pane. Comparing the
    /// whole rendered body means comparing a string that can be megabytes long;
    /// the key exists so the comparison is cheap AND still catches every change
    /// that needs a reload. Fails if a changed body or a changed blocking mode is
    /// treated as the same render, or if a banner-only change forces a reload.
    @Test func theRenderKeyTracksExactlyWhatNeedsAReload() {
        typealias Key = MessageWebView.Coordinator.RenderKey
        let base = RenderedBody(
            messageID: "m1", html: "<p>one</p>", blocksRemote: true, offersRemoteConsent: false
        )
        #expect(Key(base) == Key(base))

        // Only the consent banner differs: reloading here would flash the pane.
        var banner = base
        banner.offersRemoteConsent = true
        #expect(Key(banner) == Key(base))

        var edited = base
        edited.html = "<p>two</p>"
        #expect(Key(edited) != Key(base))

        var allowed = base
        allowed.blocksRemote = false
        #expect(Key(allowed) != Key(base))

        var other = base
        other.messageID = "m2"
        #expect(Key(other) != Key(base))
    }
}
