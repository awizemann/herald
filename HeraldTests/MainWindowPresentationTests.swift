import Foundation
import HeraldKit
import SwiftUI
import Testing
@testable import Herald

/// Redesign fix batch F2: the pure halves of the main-window fixes — the
/// reading pane's sender block and subject, the thread header while loading,
/// VoiceOver row summaries, the search match's colour on a selected row, the
/// sidebar's label-click pairing and the reading-pane CSS margin.
@MainActor
@Suite struct MainWindowPresentationTests {
    // MARK: - Reading pane sender block

    /// Fails on the old header, which drew the RAW From header as the name and
    /// took the first two characters of the whole string for the avatar ("MA"
    /// for Mara Okafor, a literal quote for a quoted "Last, First" name).
    @Test("The sender block shows the display name, list-row initials and the bare address")
    func senderBlockParsesTheFromHeader() {
        let quoted = #""Weber, Jonas" <j@x.io>"#
        #expect(ReadingPaneSender.name(quoted) == "Weber, Jonas")
        #expect(ReadingPaneSender.initials(quoted) == "WJ")
        #expect(ReadingPaneSender.address(quoted) == "j@x.io")

        let named = "Mara Okafor <mara@acme.co>"
        #expect(ReadingPaneSender.name(named) == "Mara Okafor")
        #expect(ReadingPaneSender.initials(named) == "MO")
        #expect(ReadingPaneSender.spokenAddress(named) == "mara@acme.co")

        // No display name: the name line IS the address, so it is not spoken twice.
        #expect(ReadingPaneSender.name("ops@north.io") == "ops@north.io")
        #expect(ReadingPaneSender.initials("ops@north.io") == "OP")
        #expect(ReadingPaneSender.spokenAddress("ops@north.io") == nil)
    }

    /// Fails on the old pane, which always titled itself with the thread's
    /// LATEST subject — wrong for an older message whose subject differs.
    @Test("The subject is the selected message's, falling back to the conversation's while it loads")
    func subjectFollowsTheSelectedMessage() {
        let latest = MailFixtures.message(id: "m2", threadID: "t1", subject: "Re: Budget (final)")
        let older = MailFixtures.message(id: "m1", threadID: "t1", subject: "Budget")
        let conversation = ConversationSummary(latest: latest, isStarred: false, messageCount: 2, unreadCount: 0)

        #expect(ReadingPaneSender.subject(selectedMessage: older, conversation: conversation) == "Budget")
        #expect(ReadingPaneSender.subject(selectedMessage: nil, conversation: conversation) == "Re: Budget (final)")
        #expect(ReadingPaneSender.subject(selectedMessage: nil, conversation: nil) == "")
    }

    // MARK: - Thread header

    /// Fails if the header says "0 messages · 0 people" in the gap between
    /// selecting a thread (which clears `threadMessages`) and its load.
    @Test("The thread header's summary is absent until the messages load")
    func threadSummaryWaitsForMessages() {
        #expect(ThreadMessageListView.headerSummary([]) == nil)
        let messages = [
            MailFixtures.message(id: "m1", threadID: "t1", from: "Ada <ada@x.io>"),
            MailFixtures.message(id: "m2", threadID: "t1", from: "bo@x.io"),
        ]
        #expect(ThreadMessageListView.headerSummary(messages) == "2 messages · 2 people")
    }

    // MARK: - VoiceOver row summaries

    /// Fails if either row speaks the raw server snippet — quoted history and
    /// an undecoded entity — that the screen, which draws the cleaned preview,
    /// never shows.
    @Test("Row summaries speak the cleaned snippet the row draws")
    func rowSummariesUseTheCleanedSnippet() {
        let raw = "Sounds good &amp; thanks\n> old quoted line\n> more"
        let message = MailFixtures.message(id: "m1", threadID: "t1", snippet: raw)
        let conversation = ConversationSummary(latest: message, isStarred: false, messageCount: 1, unreadCount: 0)

        let rowSummary = ConversationRow.accessibilitySummary(for: conversation)
        #expect(rowSummary.hasSuffix("Sounds good & thanks"))
        #expect(!rowSummary.contains("old quoted line"))
        #expect(!rowSummary.contains("&amp;"))

        let messageSummary = ThreadMessageRow.accessibilitySummary(for: message)
        #expect(messageSummary.hasSuffix("Sounds good & thanks"))
        #expect(!messageSummary.contains("old quoted line"))
    }

    // MARK: - Search match on a selected row

    /// Fails on the old `.primary` foreground: it resolves to the system label
    /// colour (and flips to white on a selected row's emphasised style), where
    /// the run's own opaque `match` fill does not flip — white on pale yellow.
    /// The fixed `ink` resolves to the token in both appearances.
    @Test("A matched run draws the fixed ink token on its match fill")
    func searchMatchForegroundIsFixedInk() throws {
        let attributed = SearchHighlighter.highlight("Q3 invoice", matching: "invoice")
        let run = try #require(attributed.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized })
        let foreground = try #require(run.foregroundColor)
        for scheme in [ColorScheme.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            #expect(foreground.resolve(in: environment) == MailTheme.Color.ink.resolve(in: environment), "\(scheme)")
            #expect(foreground.resolve(in: environment) != Color.primary.resolve(in: environment), "\(scheme)")
        }
    }

    // MARK: - Sidebar label clicks

    /// Fails on the old Bool flag, which stayed raised when the opening click's
    /// tap never arrived and then swallowed the NEXT click on the open label.
    @Test("A label-click mark pairs with one tap of the same label, then expires")
    func labelClickMarkPairsOnce() {
        var clicks = LabelClickDeduper()
        // The ordinary click: the setter opens, the same click's tap stands down.
        clicks.noteOpened("lbl_a", at: 10)
        let sameClick = clicks.tapIsSameClick("lbl_a", at: 10.1)
        #expect(sameClick)
        // …and the next click on the now-open label is a click of its own.
        let nextClick = clicks.tapIsSameClick("lbl_a", at: 12)
        #expect(!nextClick)

        // A mark whose tap never came does not outlive its window.
        clicks.noteOpened("lbl_a", at: 20)
        let lateTap = clicks.tapIsSameClick("lbl_a", at: 20 + LabelClickDeduper.window + 0.5)
        #expect(!lateTap)

        // A tap on a DIFFERENT label is never the opening click's tail.
        clicks.noteOpened("lbl_a", at: 30)
        let otherLabel = clicks.tapIsSameClick("lbl_b", at: 30.1)
        #expect(!otherLabel)

        // Reset (an account switch, or a click on the already-open label).
        clicks.noteOpened("lbl_a", at: 40)
        clicks.reset()
        let afterReset = clicks.tapIsSameClick("lbl_a", at: 40.1)
        #expect(!afterReset)
    }

    /// An account switch replaces the whole value; nothing may survive it.
    @Test("A fresh sidebar state carries no highlight, filter or pending click")
    func freshSidebarStateIsEmpty() {
        let fresh = SidebarTransientState()
        #expect(fresh.keyboardHighlight == nil)
        #expect(fresh.domainFilter.isEmpty && fresh.mailboxFilter.isEmpty)
        #expect(fresh.labelClicks == LabelClickDeduper())
        #expect(!fresh.movesFocusOnLevelChange)
    }

    // MARK: - Reading pane CSS margin

    /// Fails if the stylesheet's body margin and the SwiftUI inset that lines
    /// the web text up with the header stop describing the same number.
    @Test("The web document's body margin is the edge-alignment constant")
    func cssMarginMatchesEdgeAlignment() {
        let document = MailViewModel.document(wrapping: "<p>x</p>")
        let margin = Int(ReadingPaneEdgeAlignment.webContentCSSMargin)
        #expect(document.contains("margin: \(margin)px; word-break"))
        #expect(ReadingPaneEdgeAlignment.webViewInset + ReadingPaneEdgeAlignment.webContentCSSMargin
            == ReadingPaneEdgeAlignment.headerInset)
    }
}
