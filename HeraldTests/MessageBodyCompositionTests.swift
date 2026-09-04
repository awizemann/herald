import Foundation
import HeraldKit
import Testing
@testable import Herald

/// How the reading pane's document is assembled from the three fragments the
/// server splits a message into, and how `text/plain` becomes that document.
/// None of this needs a web view.
@Suite struct MessageBodyCompositionTests {
    // MARK: - Composition

    /// The bug this closes: Herald rendered `html` only, so authored text BELOW
    /// the quote (`afterQuotedHTML`) never reached the screen at all.
    @Test func allThreeFragmentsAreRenderedInOrder() {
        let body = MailViewModel.composeBody(
            html: "<p>reply</p>",
            quotedHTML: "<blockquote>old</blockquote>",
            afterQuotedHTML: "<p>postscript</p>"
        )
        for fragment in ["<p>reply</p>", "<blockquote>old</blockquote>", "<p>postscript</p>"] {
            #expect(body.contains(fragment))
        }
        let reply = try! #require(body.range(of: "<p>reply</p>"))
        let quoted = try! #require(body.range(of: "<blockquote>old</blockquote>"))
        let after = try! #require(body.range(of: "<p>postscript</p>"))
        #expect(reply.lowerBound < quoted.lowerBound)
        #expect(quoted.lowerBound < after.lowerBound)
    }

    /// JavaScript is disabled in the pane, so the collapse has to be `<details>`,
    /// closed by default, with a visible affordance.
    @Test func quotedHistoryIsACollapsedDisclosure() {
        let body = MailViewModel.composeBody(html: "<p>hi</p>", quotedHTML: "<p>old</p>")
        #expect(body.contains("<details class=\"quoted\">"))
        #expect(!body.contains("<details class=\"quoted\" open"))
        #expect(body.contains("<summary>Show quoted history</summary>"))
    }

    /// A message without history must not grow an empty disclosure — including
    /// the whitespace-only fragment the server sends for some messages.
    @Test func absentFragmentsAddNothing() {
        #expect(!MailViewModel.composeBody(html: "<p>hi</p>").contains("<details"))
        #expect(!MailViewModel.composeBody(html: "<p>hi</p>", quotedHTML: "").contains("<details"))
        #expect(!MailViewModel.composeBody(html: "<p>hi</p>", quotedHTML: "  \n ").contains("<details"))
        #expect(!MailViewModel.composeBody(html: "<p>hi</p>", afterQuotedHTML: " ").contains("after-quoted"))
    }

    /// Composition must not disturb the `cid:` rewrite, and the rewrite must
    /// reach the quoted and after-quote fragments too — inline images live in
    /// them just as often.
    @Test func inlineSubstitutionStillReachesEveryFragment() {
        let composed = MailViewModel.composeBody(
            html: "<img src=\"cid:a\">",
            quotedHTML: "<img src=\"cid:a\">",
            afterQuotedHTML: "<img src=\"cid:a\">"
        )
        let substituted = MailViewModel.substituteInlineImages(in: composed, with: ["a": "data:image/png;base64,AA"])
        #expect(!substituted.contains("cid:a"))
        #expect(substituted.components(separatedBy: "data:image/png;base64,AA").count == 4)
        #expect(substituted.contains("<summary>Show quoted history</summary>"))
    }

    // MARK: - Linkification

    @Test func barePlainTextURLsBecomeLinks() {
        let html = MailViewModel.linkifying("see https://example.com/a?x=1&y=2 now")
        #expect(html.contains("<a href=\"https://example.com/a?x=1&amp;y=2\">"))
        #expect(html.contains(">https://example.com/a?x=1&amp;y=2</a>"))
        #expect(!html.contains("&amp;amp;"), "The URL must be escaped exactly once")
        #expect(html.hasPrefix("see "))
        #expect(html.hasSuffix(" now"))
    }

    /// Escaping happens on the RAW text as each piece is emitted; linkifying
    /// already-escaped text is what produces double-escaped hrefs and entities
    /// swallowed into URLs.
    @Test func surroundingTextIsEscapedExactlyOnce() {
        let html = MailViewModel.linkifying("<b>a & b</b> https://x.test <script>")
        #expect(html.contains("&lt;b&gt;a &amp; b&lt;/b&gt;"))
        #expect(!html.contains("<b>"))
        #expect(!html.contains("<script>"))
        #expect(!html.contains("&amp;amp;"))
    }

    /// A URL is sender-controlled text landing in an ATTRIBUTE. Neither a quote
    /// nor a bracket may escape it, and only http(s) may ever become an href.
    @Test func linkificationCannotBreakOutOfTheAttribute() {
        let hostile = MailViewModel.linkifying("https://x.test/\"><script>alert(1)</script>")
        #expect(!hostile.contains("<script>"))
        #expect(!hostile.contains("\"><script"))
        #expect(hostile.contains("&lt;script&gt;"))

        #expect(!MailViewModel.linkifying("javascript:alert(1)").contains("<a "))
        #expect(!MailViewModel.linkifying("file:///etc/passwd").contains("<a "))
        #expect(!MailViewModel.linkifying("data:text/html,<b>x</b>").contains("<a "))
        // A single quote in a URL cannot close our double-quoted value either,
        // but it is escaped regardless.
        #expect(!MailViewModel.linkifying("https://x.test/'onmouseover='x").contains("onmouseover='x'"))
    }

    /// Herald manufactures these links out of inert text, so a URL whose visible
    /// host is not the host that would open stays plain text.
    @Test func deceptiveAuthoritiesAreNotLinkified() {
        for url in [
            "https://apple.com@evil.example/x",
            "https://apple.com\\@evil.example/x",
            "https://apple.com\\.evil.example/",
        ] {
            let html = MailViewModel.linkifying("see \(url)")
            #expect(!html.contains("<a "), "\(url) must stay text")
            #expect(html.contains("evil.example") || html.contains("apple.com"))
        }
        // An ordinary URL is still a link.
        #expect(MailViewModel.linkifying("https://apple.com/x").contains("<a href=\"https://apple.com/x\">"))
    }

    @Test func trailingSentencePunctuationStaysOutOfTheURL() {
        #expect(MailViewModel.linkifying("go to https://x.test/a.").contains(">https://x.test/a</a>."))
        #expect(MailViewModel.linkifying("(https://x.test/a)").contains(">https://x.test/a</a>)"))
        // Balanced parentheses inside a path are part of it.
        #expect(MailViewModel.linkifying("https://x.test/a_(b)").contains(">https://x.test/a_(b)</a>"))
    }

    // MARK: - Plain text

    @Test func plainTextQuotesAreTintedAndFolded() {
        let body = MailViewModel.plainTextBody(
            """
            Sure, that works.

            On Tue, Ada wrote:
            > the original
            > second line
            """
        )
        #expect(body.contains("Sure, that works."))
        #expect(body.contains("<details class=\"quoted\">"))
        let disclosure = try! #require(body.range(of: "<details"))
        #expect(try! #require(body.range(of: "On Tue, Ada wrote:")).lowerBound > disclosure.lowerBound)
        #expect(body.contains("<span class=\"quote-line\">&gt; the original</span>"))
        // The visible half keeps its own <pre>, so wrapping is preserved.
        #expect(body.contains("<pre class=\"plain\">"))
    }

    @Test func plainTextWithoutHistoryGetsNoDisclosure() {
        let body = MailViewModel.plainTextBody("Just a note.\n\nThanks")
        #expect(!body.contains("<details"))
        #expect(body.contains("Just a note.\n\nThanks"))
    }

    /// A quote sitting mid-message is not a trailing history and must stay in
    /// place; only the run that reaches the end is folded.
    @Test func onlyTheTrailingQuoteRunIsFolded() {
        #expect(MailViewModel.quotedTailStart(in: ["> old", "", "my reply"]) == 3)
        #expect(MailViewModel.quotedTailStart(in: ["hi", "On x wrote:", "> old"]) == 1)
        #expect(MailViewModel.quotedTailStart(in: ["hi", "> old", ""]) == 1)
        #expect(MailViewModel.quotedTailStart(in: ["hi"]) == 1)
        #expect(MailViewModel.quotedTailStart(in: []) == 0)
    }

    @Test func plainTextIsEscapedAndRendersInTheSystemFont() {
        let document = MailViewModel.document(wrappingPlainText: "<script>alert(1)</script>")
        #expect(!document.contains("<script>"))
        #expect(document.contains("&lt;script&gt;"))
        #expect(document.contains("pre.plain { font-family: -apple-system"))
    }

    // MARK: - Stylesheet and remote-media gating

    /// Dark-mode normalization styles the document's OWN regions from the design
    /// tokens; it must never try to invert a sender's colours.
    @Test func theStyleSheetCarriesTheThemeTokens() {
        let document = MailViewModel.document(wrapping: "<p>hi</p>")
        #expect(document.contains(MailTheme.Web.light.foreground))
        #expect(document.contains(MailTheme.Web.dark.background))
        #expect(document.contains("@media (prefers-color-scheme: dark)"))
        #expect(document.contains("color-scheme: light dark"))
        // Nested quote levels are told apart.
        #expect(document.contains("blockquote blockquote { border-left-color: var(--quote-2); }"))
        // Wide content scrolls inside its section rather than moving the page.
        #expect(document.contains("section.body { overflow-x: auto; }"))
        #expect(!document.contains("filter: invert"))
    }

    /// Increase Contrast is a system setting the pane used to ignore: the two
    /// dimmed tokens move toward the foreground, per appearance, and the dark
    /// override must come AFTER the dark palette or it loses at equal specificity.
    @Test func theStyleSheetHonoursIncreaseContrast() throws {
        let document = MailViewModel.document(wrapping: "<p>hi</p>")

        #expect(document.contains("@media (prefers-contrast: more)"))
        #expect(document.contains(MailTheme.Web.light.secondaryIncreasedContrast))
        #expect(document.contains(MailTheme.Web.dark.linkIncreasedContrast))

        let darkPalette = try #require(document.range(of: "@media (prefers-color-scheme: dark) { :root"))
        let darkContrast = try #require(
            document.range(of: "@media (prefers-color-scheme: dark) and (prefers-contrast: more)")
        )
        #expect(darkPalette.upperBound < darkContrast.lowerBound)

        // The quoted-history disclosure is a control, and says so on hover.
        #expect(document.contains("details.quoted > summary { cursor: pointer;"))
    }

    /// Fragments must not be able to close Herald's own disclosure or draw a
    /// second one: that is message content impersonating app chrome.
    @Test func fragmentsCannotForgeOrEscapeTheDisclosure() {
        let body = MailViewModel.composeBody(
            html: "<p>hi</p></details><summary>Herald says: trusted</summary>",
            quotedHTML: "<p>old</p></DETAILS><details open>evil</details>"
        )
        #expect(body.components(separatedBy: "<details").count == 2, "Exactly one disclosure, ours")
        #expect(body.components(separatedBy: "</details>").count == 2)
        #expect(body.components(separatedBy: "<summary>").count == 2)
        #expect(body.contains("Herald says: trusted"), "Inner content is kept, only the tags go")
        #expect(body.contains("<p>old</p>"))
    }

    /// Remote images that live only in the collapsed history still get a consent
    /// affordance — expanding is one click and this banner is the only route to
    /// trusting the sender — but the banner names the right part of the message.
    @Test func theConsentBannerNamesWhereTheBlockedImagesAre() {
        func payload(main: Bool, quoted: Bool, after: Bool) -> MessageHTML {
            MessageHTML(
                html: "<p>hi</p>", quotedHTML: "<p>old</p>", afterQuotedHTML: "<p>ps</p>",
                hasRemoteImages: main || quoted || after,
                htmlHasRemoteImages: main,
                quotedHTMLHasRemoteImages: quoted,
                afterQuotedHTMLHasRemoteImages: after,
                remoteMediaTrusted: false
            )
        }
        // Consent is offered in every case where something was blocked.
        for flags in [(true, false, false), (false, true, false), (false, false, true)] {
            #expect(payload(main: flags.0, quoted: flags.1, after: flags.2).needsRemoteMediaConsent)
        }
        #expect(payload(main: false, quoted: true, after: false).remoteImagesAreOnlyInQuotedHistory)
        #expect(!payload(main: true, quoted: true, after: false).remoteImagesAreOnlyInQuotedHistory)
        #expect(!payload(main: false, quoted: true, after: true).remoteImagesAreOnlyInQuotedHistory)
        #expect(!payload(main: false, quoted: false, after: false).remoteImagesAreOnlyInQuotedHistory)

        // A trusted sender is never asked again.
        let trusted = MessageHTML(
            html: "", quotedHTML: nil, hasRemoteImages: true,
            htmlHasRemoteImages: true, remoteMediaTrusted: true
        )
        #expect(!trusted.needsRemoteMediaConsent)

        // An instance older than the per-fragment flags reports only the
        // aggregate: it must be attributed to the main body, not to the quote.
        let legacy = MessageHTML(html: "", quotedHTML: nil, hasRemoteImages: true, remoteMediaTrusted: false)
        #expect(legacy.needsRemoteMediaConsent)
        #expect(!legacy.remoteImagesAreOnlyInQuotedHistory)
    }
}
