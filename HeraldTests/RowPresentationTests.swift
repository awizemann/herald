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

@MainActor
@Suite struct MailboxColorAssignmentTests {
    /// The default colour must be identical on every launch and every machine.
    /// Fails on the natural implementation — `address.hashValue % count` — because
    /// `Hasher` is seeded per process: the mailboxes would recolour on relaunch.
    /// Pinned literals, not just self-consistency, is the only way to catch it.
    @Test func theDefaultTokenIsPinnedToTheAddress() {
        #expect(MailboxColorAssignment.defaultToken(forAddress: "support@example.com") == "purple")
        #expect(MailboxColorAssignment.defaultToken(forAddress: "billing@example.com") == "teal")
        // Case is not part of the identity of an address.
        #expect(
            MailboxColorAssignment.defaultToken(forAddress: "Support@Example.com")
                == MailboxColorAssignment.defaultToken(forAddress: "support@example.com")
        )
    }

    /// A hash that spreads badly is as useless as no colour at all. Fails if the
    /// assignment collapses (e.g. keying off the first character, or a modulo of a
    /// near-constant hash) — twelve realistic addresses land on at least five of
    /// the eight tokens.
    @Test func differentAddressesSpreadAcrossThePalette() {
        let addresses = [
            "support@example.com", "billing@example.com", "sales@example.com",
            "hello@example.com", "press@example.com", "jobs@example.com",
            "alan@wizemann.com", "ops@herald.test", "team@herald.test",
            "noreply@herald.test", "security@example.org", "legal@example.org",
        ]
        let tokens = Set(addresses.map { MailboxColorAssignment.defaultToken(forAddress: $0) })
        #expect(tokens.count >= 5)
        // And every token is a real palette entry, not an empty or stale name.
        for token in tokens { #expect(MailTheme.mailboxTint(named: token) != nil) }
    }

    /// An override replaces the default; an override naming a token this build no
    /// longer ships falls BACK to the default rather than to nothing. Fails if the
    /// resolve order is inverted or if a stale token is trusted blindly.
    @Test func theOverrideWinsAndAStaleOneDoesNot() {
        let address = "support@example.com"  // default resolves to "purple"
        let fallback = MailboxColorAssignment.defaultToken(forAddress: address)
        #expect(MailboxColorAssignment.token(forAddress: address, override: "brown") == "brown")
        #expect(MailboxColorAssignment.token(forAddress: address, override: nil) == fallback)
        #expect(MailboxColorAssignment.token(forAddress: address, override: "chartreuse") == fallback)
    }

    /// The persistence key has to be scoped per account: two accounts can hold
    /// mailboxes with the same id and would otherwise share one colour.
    @Test func theStorageKeyIsScopedByAccount() {
        #expect(
            MailboxColorAssignment.storageKey(accountID: "a1", mailboxID: "mb1")
                != MailboxColorAssignment.storageKey(accountID: "a2", mailboxID: "mb1")
        )
        #expect(
            MailboxColorAssignment.storageKey(accountID: "a1", mailboxID: "mb1")
                == "mailboxColor.a1.mb1"
        )
    }
}

@MainActor
@Suite struct MailboxColorViewModelTests {
    /// A throwaway defaults suite, so the test never reads or writes the owner's
    /// real preferences.
    private static func makeModel(defaults: UserDefaults) async throws -> MailViewModel {
        let store = try MailStore.inMemory()
        let api = FakeMailAPIClient()
        let (stream, _) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .unbounded)
        try await store.upsertMailboxes([Self.mailbox("mbA"), Self.mailbox("mbB")], accountID: "acct")
        let model = MailViewModel(
            accountID: "acct",
            accountLabel: "Test",
            api: api,
            store: store,
            actions: MailActionService(api: api, store: store),
            events: stream,
            markReadDelay: .seconds(3600),
            defaults: defaults
        )
        await model.reloadMailboxes()
        return model
    }

    private static func mailbox(_ id: String) -> Mailbox {
        Mailbox(
            id: id,
            address: "\(id)@example.com",
            addresses: [],
            displayName: id,
            isActive: true,
            accessLevel: .manager,
            createdAt: MailFixtures.epoch,
            updatedAt: MailFixtures.epoch
        )
    }

    private static func scratchDefaults() throws -> UserDefaults {
        let name = "herald.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Picking a colour must beat the default AND survive a relaunch, and Reset
    /// must put the default back rather than freeze the previous pick. Fails if
    /// the override is only held in memory, or if reset writes the default token
    /// as a new override (the mailbox would then never follow a palette change).
    @Test func anOverrideWinsPersistsAndResets() async throws {
        let defaults = try Self.scratchDefaults()
        let model = try await Self.makeModel(defaults: defaults)
        let fallback = MailboxColorAssignment.defaultToken(forAddress: "mbA@example.com")

        #expect(model.mailboxColorToken(for: "mbA") == fallback)
        #expect(model.hasMailboxColorOverride("mbA") == false)

        model.setMailboxColorToken("pink", for: "mbA")
        #expect(model.mailboxColorToken(for: "mbA") == "pink")
        #expect(model.hasMailboxColorOverride("mbA"))
        // The other mailbox is untouched — the key is per mailbox, not per account.
        #expect(model.hasMailboxColorOverride("mbB") == false)

        // A fresh view-model over the same defaults = the next launch.
        let relaunched = try await Self.makeModel(defaults: defaults)
        #expect(relaunched.mailboxColorToken(for: "mbA") == "pink")

        relaunched.setMailboxColorToken(nil, for: "mbA")
        #expect(relaunched.mailboxColorToken(for: "mbA") == fallback)
        #expect(relaunched.hasMailboxColorOverride("mbA") == false)
        #expect(
            defaults.string(
                forKey: MailboxColorAssignment.storageKey(accountID: "acct", mailboxID: "mbA")
            ) == nil
        )

        // An unknown mailbox has no colour at all, rather than a colour for "".
        #expect(model.mailboxColorToken(for: "nope") == nil)
        #expect(model.mailboxColorToken(for: nil) == nil)
    }

    /// The chip is drawn from a resolved token, so an unknown id must not paint a
    /// tint. Fails if `mailboxTint(for:)` starts defaulting to palette[0].
    @Test func theTintResolvesOnlyForKnownMailboxes() async throws {
        let model = try await Self.makeModel(defaults: try Self.scratchDefaults())
        #expect(model.mailboxTint(for: "mbA") != nil)
        #expect(model.mailboxTint(for: "nope") == nil)
    }
}

/// The accessibility strings the app SPEAKS rather than draws — the ones a
/// rendered-view test cannot reach, so they live as pure statics beside the views
/// that post them (the `accessibilitySummary`/`accessibilityPhrase` pattern).
@MainActor
@Suite struct AnnouncementCopyTests {
    /// The reauth banner's two states must be distinguishable BY EAR: the visual
    /// difference is a button being replaced by a spinner, which VoiceOver would
    /// otherwise experience as its cursor landing on nothing.
    @Test func theReauthBannerAnnouncesBothOfItsStates() {
        let manual = ReauthBanner.announcement(isAutomatic: false)
        let automatic = ReauthBanner.announcement(isAutomatic: true)

        #expect(manual != automatic)
        // The manual state's only affordance is the button, so the announcement
        // has to name it — the cursor may never reach it on its own.
        #expect(manual.contains("Sign In"))
        #expect(automatic.contains("Signing you back in"))
        // The drawn text stays the drawn text: the announcement is allowed to say
        // more, never less.
        #expect(ReauthBanner.message(isAutomatic: true) == automatic)
        #expect(ReauthBanner.message(isAutomatic: false).hasPrefix("Your session expired."))
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
