import Testing
@testable import Herald

@Suite struct SnippetCleanerTests {
    /// Real-server snippet from the dogfood inbox. Fails if quoted lines or the
    /// attribution leak into the preview, or if the reply text itself is dropped.
    @Test func quotedHistoryAndAttributionAreDropped() {
        let raw = "reply test 3\n\nOn Aug 15, 2026 at 6:43 PM, billing@memophant.co wrote:\n> Reply test 2\n> > On Aug 15, 2026 at 6:41 PM, x wrote:\n> > > This is a test."
        #expect(SnippetCleaner.clean(raw) == "reply test 3")
    }

    /// The server slices bodies, so the attribution can arrive truncated before
    /// "wrote:". Fails if the dangling "On Aug 15, 2026 at 6:43 PM, bill…" survives.
    @Test func aTruncatedAttributionFragmentIsStripped() {
        #expect(SnippetCleaner.clean("reply test 3 On Aug 15, 2026 at 6:43 PM, billing@memophant.co wrote: > Reply") == "reply test 3")
    }

    /// Fails if entities render literally (&amp;) or if a numeric entity is left as text.
    @Test func entitiesAreDecodedAndWhitespaceCollapsed() {
        #expect(SnippetCleaner.clean("Tom &amp; Jerry&#8217;s   plan\n\n\tis &lt;great&gt;") == "Tom & Jerry’s plan is <great>")
    }

    /// Fails if a forwarded-message divider (and what follows) is kept in the preview.
    @Test func forwardedDividerEndsThePreview() {
        #expect(SnippetCleaner.clean("Testing HTML\n---------- Forwarded message ----------\nFrom: x") == "Testing HTML")
    }

    /// Fails if a plain body is altered — the cleaner must be a no-op on clean text.
    @Test func plainTextIsUntouched() {
        #expect(SnippetCleaner.clean("Lunch on Friday?") == "Lunch on Friday?")
    }
}
