import Foundation

/// The short, humanized date a list row shows, and the full one its tooltip and
/// VoiceOver value carry.
///
/// Pure and `nonisolated` with an injected `now`/calendar/locale: every rule here
/// is a boundary (midnight, the sixth day, New Year) and none of them is testable
/// against the wall clock.
nonisolated enum RowDateFormatter {
    /// Longest string the compact form can produce, used to size the row's fixed
    /// date slot. Not asserted — `MailTheme.dateSlotWidth` is the real budget.
    static let longestCompactSample = "Dec 31, 2024"

    /// - today → "6:44 PM"
    /// - yesterday → "Yesterday"
    /// - the five days before that → "Tue"
    /// - earlier this year → "Aug 15"
    /// - older → "Aug 15, 2024"
    static func compact(
        _ date: Date,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0

        // A message dated in the future (clock skew on the server) reads as today
        // rather than as a negative-day weekday.
        if days <= 0 {
            return style(date: .omitted, time: .shortened, calendar, locale).format(date)
        }
        if days == 1 { return "Yesterday" }
        if days <= 6 {
            return style(date: .omitted, time: .omitted, calendar, locale)
                .weekday(.abbreviated)
                .format(date)
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        if sameYear {
            return style(date: .omitted, time: .omitted, calendar, locale)
                .month(.abbreviated)
                .day()
                .format(date)
        }
        return style(date: .abbreviated, time: .omitted, calendar, locale).format(date)
    }

    /// The unambiguous absolute date+time — what `.help()` shows on hover and what
    /// VoiceOver reads as the row's value, since "Tue" alone is not a date.
    static func full(
        _ date: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        style(date: .abbreviated, time: .shortened, calendar, locale).format(date)
    }

    private static func style(
        date: Date.FormatStyle.DateStyle,
        time: Date.FormatStyle.TimeStyle,
        _ calendar: Calendar,
        _ locale: Locale
    ) -> Date.FormatStyle {
        Date.FormatStyle(
            date: date,
            time: time,
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
    }
}
