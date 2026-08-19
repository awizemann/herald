import Foundation
import Stats
import StatsCloudflare
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "usage")

// MARK: - Seam

/// The one way Herald emits usage analytics.
///
/// `nonisolated` because the only shipping conformance is an actor, and because
/// call sites are `@MainActor` view models — an implicitly main-actor-isolated
/// protocol could not be witnessed by an actor at all (see "Herald Concurrency
/// Rules").
///
/// The `track` parameter is a ``UsageEvent``, never a `String` and never a
/// dictionary: that is what makes `UsageEvent.swift` the complete, auditable list
/// of what this app can send.
nonisolated protocol UsageTracking: Sendable {
    func track(_ event: UsageEvent) async
    /// Drives `app_open` / `session_start`. swift-stats installs no AppKit
    /// observers of its own, so Herald calls this from its existing
    /// `NSApplication.didBecomeActiveNotification` observer.
    func applicationDidBecomeActive() async
    func flush() async
    /// The user-facing opt-out (Settings → Privacy). Persisted by the SDK.
    func setEnabled(_ enabled: Bool) async
    var isEnabled: Bool { get async }
}

// MARK: - No-op

/// Collects nothing, ever. The default for `AppEnvironment.usage`, and what
/// ``UsageAnalytics/makeTracker(environment:arguments:writeKey:)`` returns under
/// tests, in a demo/mock run, and whenever no usable write key is configured.
nonisolated struct NoopUsageTracker: UsageTracking {
    init() {}

    func track(_ event: UsageEvent) async {}
    func applicationDidBecomeActive() async {}
    func flush() async {}
    func setEnabled(_ enabled: Bool) async {}
    var isEnabled: Bool { get async { false } }
}

// MARK: - Real tracker

/// Forwards to a ``StatsClient``, which is itself an actor.
///
/// Deliberately stateless — a `nonisolated struct`, not an actor. The obvious
/// design is an actor owning a "consent has been applied this process" latch, but
/// the SDK makes that both unnecessary and wrong:
///
/// - **Unnecessary.** `StatsConfiguration.consent` is documented as "initial
///   consent, used only the first time this app runs (afterwards the persisted
///   choice wins)", so seeding `.all` in the configuration is *the* API for setting
///   consent on first use. It is synchronous, so no latch, no `Task` handle, and
///   no actor reentrancy argument is needed.
/// - **Wrong.** Calling `setConsent(.all)` once per launch would re-widen any
///   consent a person had deliberately narrowed. Consent revocation is required by
///   schema §11 to be unresumable; re-granting it on their behalf at next launch
///   would break exactly that.
///
/// Verified against swift-stats 0.2.0 (additive over 0.1.0; see CHANGELOG upgrade notes).
nonisolated struct StatsUsageTracker: UsageTracking {
    private let client: StatsClient

    init(client: StatsClient) {
        self.client = client
    }

    /// Builds the shipping client. `StatsClient.init` performs no disk I/O — the
    /// queue path and the `UserDefaults` suite are both resolved lazily inside the
    /// actor on the first `track` / `applicationDidBecomeActive` (swift-stats 0.1.0,
    /// "Consumer checklist") — so this is safe to call directly in
    /// `AppEnvironment.init` on the main actor, with no `Task.detached` around it.
    init(writeKey: String, endpoint: CloudflareEndpoint) {
        self.init(client: StatsClient(configuration: StatsConfiguration(
            appId: UsageAnalytics.appId,
            projectId: UsageAnalytics.projectId,
            installIdSalt: UsageAnalytics.installIdSalt,
            sink: CloudflareSink(endpoint: endpoint, writeKey: writeKey),
            // First-run seed only; the persisted choice wins on every later launch.
            // `.identity` is in the set because counting active installs is the
            // whole point — it is what the privacy manifest and the opt-out copy
            // disclose.
            consent: .all,
            // No `.appBackground`: Herald is a mail client people leave running, so
            // an event per app switch is noise, not signal.
            autoEvents: [.appOpen, .sessions]
        )))
    }

    func track(_ event: UsageEvent) async {
        await client.track(event.name, props: event.statsProps)
    }

    func applicationDidBecomeActive() async {
        await client.applicationDidBecomeActive()
    }

    func flush() async {
        await client.flush()
    }

    func setEnabled(_ enabled: Bool) async {
        await client.setEnabled(enabled)
    }

    /// A snapshot, not a stream: the SDK publishes no change notification, so a
    /// Settings toggle must mirror this into its own state (P4).
    var isEnabled: Bool {
        get async { await client.isEnabled }
    }
}

// MARK: - Construction and gating

/// Decides whether this process gets a real tracker at all.
nonisolated enum UsageAnalytics {
    /// The app's bundle identifier — the schema's `appId` (§2).
    static let appId = "com.wizemann.herald"
    /// Advisory: the backend derives the real project from the write key (§2.4).
    static let projectId = "herald"
    /// Constant, committed, **not a secret** (§9). Its only job is to stop the
    /// per-install random UUID from being correlatable across apps or backends.
    /// Changing it silently re-identifies every install as new — never change it.
    static let installIdSalt = "herald-mac-2026"
    /// The hosted swift-stats ingest endpoint.
    static let endpointString = "https://api.swiftstats.co"
    /// Info.plist key holding the project-scoped write key. Append-only and scoped
    /// to one project, so it ships in the binary (§8); it is not a read key.
    static let writeKeyInfoPlistKey = "HeraldStatsWriteKey"

    /// Launch arguments that force the no-op tracker.
    ///
    /// **Empty on purpose.** Herald has no demo, mock, screenshot or UI-test launch
    /// flag today (`CommandLine`/`launchArguments` appear nowhere in the app). The
    /// check is wired up so that adding one here is the whole job.
    static let disablingArguments: Set<String> = []

    /// Environment variables whose mere presence means "a test harness is running".
    /// The same set ``ProcessInfo/isRunningUnderTests`` uses: `XCTestConfigurationFilePath`
    /// alone misses Swift Testing when it runs standalone.
    static let testEnvironmentKeys = [
        "XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier",
    ]

    /// Reads the write key baked in at build time. Returns `nil` when the key is
    /// absent; an unsubstituted `$(APP_STATS_WRITE_KEY)` is returned as-is and
    /// rejected by ``makeTracker(environment:arguments:writeKey:)``.
    static func writeKey(from bundle: Bundle) -> String? {
        bundle.object(forInfoDictionaryKey: writeKeyInfoPlistKey) as? String
    }

    /// The single decision point. Returns ``NoopUsageTracker`` when:
    /// - a test harness is running,
    /// - a demo/mock launch argument is present,
    /// - the write key is `nil`, empty or whitespace, or is an unsubstituted
    ///   `$(...)` build setting,
    /// - or the endpoint URL will not validate.
    static func makeTracker(
        environment: [String: String],
        arguments: [String],
        writeKey: String?
    ) -> any UsageTracking {
        for key in testEnvironmentKeys where environment[key] != nil {
            return NoopUsageTracker()
        }
        if arguments.contains(where: disablingArguments.contains) {
            return NoopUsageTracker()
        }
        guard let writeKey, isUsableWriteKey(writeKey) else {
            logger.info("usage analytics disabled: no usable write key")
            return NoopUsageTracker()
        }
        guard let endpoint = try? CloudflareEndpoint(string: endpointString) else {
            logger.error("usage analytics disabled: endpoint did not validate")
            return NoopUsageTracker()
        }
        return StatsUsageTracker(writeKey: writeKey, endpoint: endpoint)
    }

    /// A key is unusable when it is blank or still an unexpanded build setting —
    /// the shape a checkout without `APP_STATS_WRITE_KEY` produces.
    static func isUsableWriteKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("$(")
    }
}
