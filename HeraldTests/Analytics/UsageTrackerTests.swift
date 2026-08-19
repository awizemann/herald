import Foundation
import Stats
import StatsTesting
import Testing
@testable import Herald

/// End-to-end through a **real** ``StatsClient`` — the whole point being that the
/// SDK is the thing that sanitises props (schema §2.3) and refuses reserved names
/// (§12). A hand-rolled fake tracker would happily "pass" events the real emitter
/// silently drops, so this suite runs the actual client over an ``InMemorySink``
/// with deterministic ids and a throwaway storage directory.
@Suite struct UsageTrackerTests {

    /// A client whose queue lives in a fresh temp directory and whose identity
    /// suite is keyed to a unique `appId`.
    ///
    /// Both are load-bearing. swift-stats persists the opt-out, the consent set and
    /// `seq` in a `UserDefaults` suite named from the **appId alone**, and the queue
    /// defaults to Application Support — so reusing `UsageAnalytics.appId` here would
    /// let the opt-out test below silently disable collection for every other test in
    /// this suite, and would write to the real app's stores from a test run.
    private static func makeClient(appId: String, sink: InMemorySink, directory: URL) -> StatsClient {
        StatsClient(configuration: StatsConfiguration(
            appId: appId,
            projectId: UsageAnalytics.projectId,
            installIdSalt: UsageAnalytics.installIdSalt,
            sink: sink,
            // High enough that nothing auto-flushes mid-run: every batch boundary
            // here is one this test asked for.
            flushAt: 10_000,
            flushInterval: .seconds(86_400),
            consent: .all,
            autoEvents: .none,
            storageDirectory: directory,
            uuidProvider: FixedUUIDProvider(),
            randomSource: FixedRandomSource()
        ))
    }

    /// A client, its temp queue directory and its throwaway identity suite, plus the
    /// teardown for both.
    private struct Harness {
        let appId: String
        let directory: URL
        let sink: InMemorySink
        let tracker: StatsUsageTracker

        init() throws {
            appId = "com.wizemann.herald.usagetests.\(UUID().uuidString)"
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("herald-usage-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            sink = InMemorySink()
            tracker = StatsUsageTracker(
                client: UsageTrackerTests.makeClient(appId: appId, sink: sink, directory: directory)
            )
            UsageTrackerTests.sweepStale()
        }

        /// Removes the queue directory AND the identity suite — the whole suite,
        /// not just its contents.
        ///
        /// `UserDefaults.standard.removePersistentDomain(forName:)` empties the
        /// domain but leaves the suite registered and its backing file behind, so
        /// every run of this file used to deposit another empty
        /// `com.wizemann.stats.com.wizemann.herald.usagetests.<uuid>.plist` in the
        /// app container's Preferences directory, forever. Emptying it through the
        /// suite's own `UserDefaults`, unregistering it, and deleting the file is
        /// what actually leaves nothing behind.
        func tearDown() {
            try? FileManager.default.removeItem(at: directory)
            let suite = "com.wizemann.stats.\(appId)"
            let suiteDefaults = UserDefaults(suiteName: suite)
            suiteDefaults?.removePersistentDomain(forName: suite)
            // Flushed BEFORE the file is deleted: `cfprefsd` writes back on its
            // own schedule, and a write-back that lands after the delete puts the
            // (now empty) plist straight back.
            suiteDefaults?.synchronize()
            UserDefaults.standard.removeSuite(named: suite)
            UserDefaults.standard.synchronize()
            if let url = UsageTrackerTests.preferencesFileURL(forSuite: suite) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Removes `usagetests` identity plists left over from EARLIER runs, once per
    /// run, before the first harness is built.
    ///
    /// The in-process teardown below is necessary but cannot be sufficient on its
    /// own: `cfprefsd` — not this process — owns the file, and it can write an
    /// empty plist back for a domain we emptied after the test process has
    /// exited. Rather than race the daemon, the next run simply sweeps what the
    /// previous one left; those files belong to no live process.
    private static let sweptStale: Void = {
        guard let preferences = preferencesFileURL(forSuite: "any")?.deletingLastPathComponent(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: preferences.path)
        else { return }
        for name in names where name.hasPrefix("com.wizemann.stats.com.wizemann.herald.usagetests.") {
            try? FileManager.default.removeItem(at: preferences.appendingPathComponent(name))
        }
    }()

    static func sweepStale() { _ = sweptStale }

    /// Where a `UserDefaults` suite's plist lands for this process — inside the
    /// app container when the host is sandboxed, which is exactly where the stray
    /// files were accumulating.
    static func preferencesFileURL(forSuite suite: String) -> URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(suite).plist")
    }

    /// The teardown, tested. Fails if a run of this suite leaves its throwaway
    /// identity suite behind — as a registered domain or as a file — which is how
    /// the container filled up with empty `usagetests` plists in the first place.
    @Test func theHarnessTearDownLeavesNoSuiteBehind() async throws {
        let harness = try Harness()
        let suite = "com.wizemann.stats.\(harness.appId)"
        // Make the SDK actually create the suite, so the teardown has something
        // to remove and this test cannot pass vacuously.
        await harness.tracker.track(.draftSaved)
        await harness.tracker.flush()
        try #require(UserDefaults.standard.persistentDomain(forName: suite) != nil)

        harness.tearDown()

        // The file is the assertion that matters: `cfprefsd` keeps answering for
        // a domain it has already seen this process, so `persistentDomain` may
        // hand back an EMPTY dictionary rather than nil — what must not survive
        // is the plist on disk.
        #expect(UserDefaults.standard.persistentDomain(forName: suite)?.isEmpty ?? true)
        if let url = Self.preferencesFileURL(forSuite: suite) {
            #expect(!FileManager.default.fileExists(atPath: url.path), "left \(url.lastPathComponent)")
        }
    }

    /// Would fail if a name were rejected by the SDK's `isValidForApp` (the event
    /// never arrives) or if a prop key/value were dropped by §2.3 sanitisation — both
    /// of which are invisible from the call site and would show up as a missing
    /// dimension on the dashboard weeks later.
    @Test func everyFixtureEventReachesTheSinkInOrderWithPropsIntact() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        for event in UsageEventFixtures.all {
            await harness.tracker.track(event)
        }
        await harness.tracker.flush()

        let sent = await harness.sink.sentEvents
        let names = await harness.sink.sentEventNames
        #expect(names == UsageEventFixtures.all.map(\.name))
        try #require(sent.count == UsageEventFixtures.all.count)
        for (received, expected) in zip(sent, UsageEventFixtures.all) {
            #expect(received.props == expected.statsProps, "props changed in flight for \(expected.name)")
            #expect(received.appId == harness.appId)
            #expect(received.userId == nil, "Herald never calls identify(userID:)")
        }
        // `seq` is strictly increasing (§2.2) — a reader detects dropped batches by it.
        #expect(sent.map(\.seq) == sent.map(\.seq).sorted())
    }

    /// The opt-out has to actually stop collection, not just hide the toggle. The
    /// first half proves an event WOULD have been sent, so the second half cannot
    /// pass vacuously; then it fails if anything queued before the opt-out is still
    /// delivered afterwards, or if capture continues.
    @Test func optingOutStopsCollectionAndDiscardsWhatWasQueued() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        await harness.tracker.track(.draftSaved)
        await harness.tracker.flush()
        #expect(await harness.sink.sentEventNames == ["draft_saved"])

        await harness.tracker.track(.remoteMediaLoaded)  // queued, never flushed
        await harness.tracker.setEnabled(false)
        #expect(await harness.tracker.isEnabled == false)
        await harness.tracker.track(.attachmentSaved)  // must not be captured at all
        await harness.tracker.flush()

        #expect(
            await harness.sink.sentEventNames == ["draft_saved"],
            "nothing may be sent after an opt-out, including what was already queued"
        )
    }

    /// The no-op must be inert in every direction, including `isEnabled` — a Settings
    /// toggle reading `true` from a tracker that collects nothing is a lie in the UI.
    @Test func noopTrackerCollectsNothingAndReportsDisabled() async {
        let tracker = NoopUsageTracker()
        await tracker.track(.draftSaved)
        await tracker.applicationDidBecomeActive()
        await tracker.flush()
        await tracker.setEnabled(true)
        #expect(await tracker.isEnabled == false)
    }
}

/// The gate that decides whether this process collects anything at all. Every row is
/// a way a build could otherwise start phoning home from a place it must not: a test
/// run, a demo, or a checkout with no key configured.
@Suite struct UsageAnalyticsGatingTests {
    nonisolated struct Row: Sendable, CustomTestStringConvertible {
        let label: String
        let environment: [String: String]
        let arguments: [String]
        let writeKey: String?
        let expectsNoop: Bool
        var testDescription: String { label }
    }

    nonisolated static let rows: [Row] = [
        Row(label: "XCTestConfigurationFilePath present",
            environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"],
            arguments: [], writeKey: "live-key", expectsNoop: true),
        Row(label: "XCTestBundlePath present (Swift Testing standalone)",
            environment: ["XCTestBundlePath": "/tmp/x.xctest"],
            arguments: [], writeKey: "live-key", expectsNoop: true),
        Row(label: "XCTestSessionIdentifier present",
            environment: ["XCTestSessionIdentifier": "abc"],
            arguments: [], writeKey: "live-key", expectsNoop: true),
        Row(label: "nil write key",
            environment: [:], arguments: [], writeKey: nil, expectsNoop: true),
        Row(label: "empty write key",
            environment: [:], arguments: [], writeKey: "", expectsNoop: true),
        Row(label: "whitespace-only write key",
            environment: [:], arguments: [], writeKey: "   \n\t ", expectsNoop: true),
        Row(label: "unsubstituted build setting",
            environment: [:], arguments: [], writeKey: "$(APP_STATS_WRITE_KEY)", expectsNoop: true),
        Row(label: "clean environment and a real key",
            environment: [:], arguments: [], writeKey: "live-key", expectsNoop: false),
        Row(label: "unrelated environment and arguments do not disable",
            environment: ["HOME": "/Users/nobody"], arguments: ["-NSDocumentRevisionsDebugMode", "YES"],
            writeKey: "live-key", expectsNoop: false),
    ]

    /// Fails if any of these ever produces a live tracker — the one bug in this
    /// feature that cannot be taken back once a build ships.
    @Test(arguments: rows)
    func gatingTable(row: Row) {
        let tracker = UsageAnalytics.makeTracker(
            environment: row.environment,
            arguments: row.arguments,
            writeKey: row.writeKey
        )
        #expect((tracker is NoopUsageTracker) == row.expectsNoop, "\(row.label)")
    }

    /// No test may touch the SHIPPING identity suite. swift-stats keeps the
    /// install UUID, the consent set, the opt-out and `seq` in a `UserDefaults`
    /// suite named from the appId alone, so a test that let a live client reach it
    /// would rewrite a real person's install identity on the developer's machine —
    /// and a test that flipped the opt-out there would silently disable collection
    /// for the installed app. Fails if building the live tracker creates, empties
    /// or otherwise disturbs that suite or its file.
    @Test func buildingTheLiveTrackerNeverTouchesTheProductionSuite() {
        let suite = "com.wizemann.stats.\(UsageAnalytics.appId)"
        let url = UsageTrackerTests.preferencesFileURL(forSuite: suite)
        let before = url.map { FileManager.default.contents(atPath: $0.path) }
        let domainBefore = UserDefaults.standard.persistentDomain(forName: suite) as NSDictionary?

        let tracker = UsageAnalytics.makeTracker(
            environment: [:], arguments: [], writeKey: "live-key"
        )
        #expect(!(tracker is NoopUsageTracker), "otherwise this passes vacuously")

        let domainAfter = UserDefaults.standard.persistentDomain(forName: suite) as NSDictionary?
        #expect(domainAfter == domainBefore, "the production suite changed")
        if let url {
            let after = FileManager.default.contents(atPath: url.path)
            #expect(after == before, "\(url.lastPathComponent) was created or rewritten")
        }
    }

    /// The constants are load-bearing: `installIdSalt` re-identifies every install if
    /// it changes, and `appId` must equal the real bundle id or the backend 400s the
    /// batch (schema §0 field enforcement).
    @Test func identityConstantsAreTheOnesTheBackendExpects() {
        #expect(UsageAnalytics.appId == "com.wizemann.herald")
        #expect(UsageAnalytics.appId == Bundle.main.bundleIdentifier)
        #expect(UsageAnalytics.projectId == "herald")
        #expect(UsageAnalytics.installIdSalt == "herald-mac-2026")
        #expect(UsageAnalytics.endpointString == "https://api.swiftstats.co")
    }

    /// P2 adds `HeraldStatsWriteKey` = `$(APP_STATS_WRITE_KEY)` to the app's Info.plist.
    /// This pins the key name both sides must agree on, and proves the reader returns
    /// `nil` (rather than trapping) for a bundle that has no such key — the state of a
    /// fresh clone, and of this very test bundle.
    @Test func writeKeyReaderUsesTheAgreedPlistKeyAndToleratesItsAbsence() {
        #expect(UsageAnalytics.writeKeyInfoPlistKey == "HeraldStatsWriteKey")
        #expect(UsageAnalytics.writeKey(from: Bundle(for: BundleToken.self)) == nil)
    }

    /// The four shapes a key can take. Fails if the `$(` check is ever dropped — the
    /// regression that ships a build POSTing the literal string `$(APP_STATS_WRITE_KEY)`
    /// as its credential.
    @Test(arguments: [
        ("live-key", true),
        ("", false),
        ("  \n ", false),
        ("$(APP_STATS_WRITE_KEY)", false),
        ("  $(APP_STATS_WRITE_KEY)  ", false),
    ])
    func writeKeyUsability(key: String, isUsable: Bool) {
        #expect(UsageAnalytics.isUsableWriteKey(key) == isUsable)
    }
}

/// Anchors `Bundle(for:)` to the test bundle.
private final class BundleToken {}
