import Foundation
import HeraldKit
import Testing
@testable import Herald

/// A fixed clock and a fixed calendar: every rule in `RowDateFormatter` is a
/// boundary, and none of them can be asserted against the wall clock.
@MainActor
@Suite struct RowDateFormatterTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private static let locale = Locale(identifier: "en_US")

    private static func date(_ components: DateComponents) -> Date {
        var components = components
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        return calendar.date(from: components)!
    }

    private static func compact(_ date: Date, now: Date) -> String {
        RowDateFormatter.compact(date, now: now, calendar: calendar, locale: locale)
    }

    /// The today/yesterday split is a CALENDAR-DAY split, not a 24-hour one.
    /// Fails on the obvious implementation (`now.timeIntervalSince(date) < 86400`),
    /// which calls 23:59 tonight and 00:01 this morning the same bucket and shows
    /// a time for a message that was actually sent yesterday.
    @Test func midnightSplitsTodayFromYesterdayByCalendarDay() {
        let now = Self.date(DateComponents(year: 2026, month: 8, day: 16, hour: 0, minute: 30))
        let lateYesterday = Self.date(
            DateComponents(year: 2026, month: 8, day: 15, hour: 23, minute: 59)
        )
        let earlyToday = Self.date(DateComponents(year: 2026, month: 8, day: 16, hour: 0, minute: 1))

        #expect(Self.compact(lateYesterday, now: now) == "Yesterday")
        // Two minutes apart from the one above, and a different bucket.
        #expect(Self.compact(earlyToday, now: now).contains(":"))
    }

    /// The weekday window is six days wide. Fails if it is written as `< 7` or
    /// `<= 7`, where "Sun" would be shown for a message exactly one week old and
    /// read as three days from now.
    @Test func theWeekdayWindowStopsAfterSixDays() {
        let now = Self.date(DateComponents(year: 2026, month: 8, day: 16, hour: 12))
        let sixDaysAgo = Self.date(DateComponents(year: 2026, month: 8, day: 10, hour: 9))
        let sevenDaysAgo = Self.date(DateComponents(year: 2026, month: 8, day: 9, hour: 9))

        #expect(Self.compact(sixDaysAgo, now: now) == "Mon")
        #expect(Self.compact(sevenDaysAgo, now: now) == "Aug 9")
    }

    /// A year boundary is not a day count. Fails if "same year" is approximated
    /// as "within N days", which would print "Dec 31" with no year for a message
    /// from last year — indistinguishable from one due this December.
    @Test func theYearAppearsOnceTheCalendarYearDiffers() {
        let now = Self.date(DateComponents(year: 2026, month: 1, day: 1, hour: 10))
        let newYearsEve = Self.date(DateComponents(year: 2025, month: 12, day: 31, hour: 22))
        #expect(Self.compact(newYearsEve, now: now) == "Yesterday")

        let laterInJanuary = Self.date(DateComponents(year: 2026, month: 1, day: 20, hour: 10))
        #expect(Self.compact(newYearsEve, now: laterInJanuary).contains("2025"))

        // Same year, older than the weekday window: month and day, no year.
        let december = Self.date(DateComponents(year: 2026, month: 12, day: 20, hour: 10))
        let decemberFirst = Self.date(DateComponents(year: 2026, month: 12, day: 1, hour: 10))
        #expect(Self.compact(decemberFirst, now: december) == "Dec 1")
    }

    /// The compact form alone is ambiguous, so the tooltip / VoiceOver value has
    /// to carry the absolute date AND the time. Fails if `full` is quietly made
    /// the same string as `compact`.
    @Test func theFullFormCarriesDateAndTime() {
        let date = Self.date(DateComponents(year: 2025, month: 8, day: 15, hour: 18, minute: 44))
        let full = RowDateFormatter.full(date, calendar: Self.calendar, locale: Self.locale)
        #expect(full.contains("2025"))
        #expect(full.contains("Aug"))
        #expect(full.contains("6:44"))
    }
}

/// The accessibility strings the app SPEAKS rather than draws — the ones a
/// rendered-view test cannot reach, so they live as pure statics beside the views
/// that post them (the `accessibilitySummary`/`accessibilityPhrase` pattern).
@MainActor
@Suite struct AnnouncementCopyTests {
    /// The reauth banner's states must be distinguishable BY EAR: the visual
    /// difference is one button being swapped for another under a spinner, which
    /// VoiceOver would otherwise experience as its cursor landing on something
    /// else. Each announcement names the control the state offers — the cursor
    /// may never reach it on its own. Fails if the in-progress announcement
    /// stops naming Cancel (the control P3 added for automatic attempts too), or
    /// if a cancel is announced as a fresh expiry.
    @Test func theReauthBannerAnnouncesEachOfItsStates() {
        let idle = ReauthBanner.announcement(isReauthenticating: false)
        let running = ReauthBanner.announcement(isReauthenticating: true)
        let cancelled = ReauthBanner.cancelledAnnouncement

        #expect(Set([idle, running, cancelled]).count == 3)
        #expect(idle.contains("Sign In"))
        #expect(running.contains("Signing you back in"))
        #expect(running.contains("Cancel"))
        #expect(cancelled.contains("cancelled"))
        #expect(cancelled.contains("Sign In"), "after a cancel the way back in is the Sign In button")
        // The drawn text stays the drawn text: the announcement is allowed to say
        // more, never less.
        #expect(running.hasPrefix(ReauthBanner.message(isReauthenticating: true)))
        #expect(ReauthBanner.message(isReauthenticating: false).hasPrefix("Your session expired."))
    }

    /// One source for what the banner draws and what it announces. Fails if the
    /// two ever drift into separately worded copies.
    @Test func theImageBannersSayTheSameThingTheyDraw() {
        #expect(
            MessageBodySection.remoteConsentText(quotedHistoryOnly: true)
                != MessageBodySection.remoteConsentText(quotedHistoryOnly: false)
        )
        #expect(MessageBodySection.remoteConsentText(quotedHistoryOnly: true).contains("quoted history"))
        // Singular/plural: "1 images" in a spoken announcement is worse than on
        // screen, where it is at least skimmed past.
        #expect(MessageBodySection.inlineImageFailureText(count: 1) == "An image embedded in this message could not be loaded.")
        #expect(MessageBodySection.inlineImageFailureText(count: 3).hasPrefix("3 images"))
    }

    /// Search announces RESULTS only. The bar's text also changes on every
    /// debounced keystroke while the server tier runs, and speaking those would
    /// talk over the user typing.
    @Test func searchAnnouncesSettledStatesOnly() {
        #expect(SearchStatusBar.announces(.idle) == false)
        #expect(SearchStatusBar.announces(.searching) == false)
        #expect(SearchStatusBar.announces(.completed(4)))
        #expect(SearchStatusBar.announces(.failed("offline")))
    }
}
