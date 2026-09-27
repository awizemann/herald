import Foundation
import Synchronization
import Testing

/// Throwaway `UserDefaults` suites for tests — and the cleanup that actually
/// removes them.
///
/// The test bundle runs inside the sandboxed Herald.app, so every suite lands as
/// a plist in the app container's Preferences directory, next to the real app's
/// own. `removePersistentDomain(forName:)` only EMPTIES a suite: its plist stays
/// behind, which is how thousands of `<Suite>.<UUID>.plist` files piled up there.
///
/// Every suite made here is registered with the running test's
/// ``ScratchDefaultsScope`` (the `.scratchDefaults` trait) and discarded — domain
/// emptied, flushed, file deleted — when that test ends. That keeps the directory
/// clean while the run is going, but it cannot be the last word: when the test
/// host exits, `cfprefsd` flushes every domain the process touched and writes an
/// EMPTY plist back for each discarded suite (observed: all of a run's suites
/// reappear in the same second, at exit). Those belong to no live process, so the
/// first scratch suite of the NEXT run sweeps them.
nonisolated enum ScratchDefaults {
    /// Every scratch suite's name starts with this, so the sweep can find them
    /// and nothing else.
    static let prefix = "HeraldTests."

    /// A fresh, empty suite that is deleted when the current test ends.
    static func make(fileID: String = #fileID) -> UserDefaults {
        let suite = suiteName(fileID: fileID)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// A unique suite name registered for deletion when the current test ends —
    /// for code that opens the suite itself (the UI-test harness).
    ///
    /// Records an issue when called outside a `.scratchDefaults` scope: the suite
    /// would otherwise outlive the test and leak its plist.
    static func suiteName(fileID: String = #fileID) -> String {
        sweepStale()
        let label = fileID.split(separator: "/").last.map { $0.replacingOccurrences(of: ".swift", with: "") } ?? "Test"
        let suite = "\(prefix)\(label).\(UUID().uuidString)"
        if let registry {
            registry.suites.withLock { $0.append(suite) }
        } else {
            Issue.record("ScratchDefaults used outside a .scratchDefaults test; \(suite) would leak its plist")
        }
        return suite
    }

    /// Empties the suite, flushes it, and deletes its file.
    ///
    /// The flush comes BEFORE the delete: `cfprefsd` writes back on its own
    /// schedule, and a write-back that lands after the delete puts the (empty)
    /// plist straight back.
    static func discard(_ suite: String) {
        let defaults = UserDefaults(suiteName: suite)
        defaults?.removePersistentDomain(forName: suite)
        defaults?.synchronize()
        UserDefaults.standard.removeSuite(named: suite)
        UserDefaults.standard.synchronize()
        try? FileManager.default.removeItem(at: fileURL(forSuite: suite))
    }

    /// Where a suite's plist lands for this process — inside the app container
    /// when the host is sandboxed.
    static func fileURL(forSuite suite: String) -> URL {
        preferencesDirectory.appendingPathComponent("\(suite).plist")
    }

    /// Deletes plists whose name starts with `prefix` and that were last written
    /// more than `age` ago — leftovers of EARLIER runs, which no live process owns.
    ///
    /// The age floor keeps a concurrent test run (another worktree building the
    /// same bundle id shares this container) from losing a suite mid-test; no
    /// test runs anywhere near five minutes.
    static func sweep(prefix: String, olderThan age: TimeInterval = 5 * 60) {
        let directory = preferencesDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".plist") {
            let url = directory.appendingPathComponent(name)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: - Plumbing

    /// The suites the running test has made, until its scope discards them.
    final class Registry: Sendable {
        let suites = Mutex<[String]>([])
    }

    @TaskLocal static var registry: Registry?

    private static let preferencesDirectory: URL =
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences", isDirectory: true)

    /// Once per process, before the first scratch suite exists.
    private static let sweptStale: Void = sweep(prefix: prefix)
    private static func sweepStale() { _ = sweptStale }
}

/// Discards every ``ScratchDefaults`` suite a test made once that test ends.
/// Apply to a suite as `.scratchDefaults`; it reaches every test (and every
/// argument of a parameterized one) inside it.
nonisolated struct ScratchDefaultsScope: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    /// One scope per test-case run — the level at which the body executes.
    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable @concurrent () async throws -> Void
    ) async throws {
        let registry = ScratchDefaults.Registry()
        defer { for suite in registry.suites.withLock({ $0 }) { ScratchDefaults.discard(suite) } }
        try await ScratchDefaults.$registry.withValue(registry, operation: function)
    }
}

extension Trait where Self == ScratchDefaultsScope {
    /// Deletes the test's ``ScratchDefaults`` suites when it ends.
    static var scratchDefaults: Self { Self() }
}
