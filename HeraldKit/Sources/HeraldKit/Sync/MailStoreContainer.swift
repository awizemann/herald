import Foundation
import OSLog
import SwiftData

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "MailStoreContainer")

/// The ONE place the cache's `Schema` is declared and the ONE place a
/// `ModelContainer` is built.
///
/// Everything here is `nonisolated` so the container can be opened off-main
/// (`Task.detached { MailStoreContainer.make() }`) — opening a store does file
/// I/O and must never run on the main actor.
public nonisolated enum MailStoreContainer {
    /// Canonical model list. Adding a model means adding it here and nowhere else.
    public static var models: [any PersistentModel.Type] {
        [
            CachedMailbox.self,
            CachedConversation.self,
            CachedMessage.self,
            CachedMessageBody.self,
            CachedDraft.self,
            CachedLabel.self,
            CachedLabelAssignment.self,
            CachedSyncCheckpoint.self,
        ]
    }

    /// Canonical schema. No `VersionedSchema`: the store is a rebuildable cache.
    public static var schema: Schema { Schema(models) }

    /// Default on-disk location (Application Support), safe to delete at any time.
    public static var defaultStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        // Debug builds keep a separate cache, matching their separate Keychain
        // namespace (see KeychainStore.defaultService): a dev copy and the release
        // app never share a store, so both can run at once.
        #if DEBUG
        let folder = "Herald-Debug"
        #else
        let folder = "Herald"
        #endif
        return base
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("MailCache.store")
    }

    /// In-memory container for tests and previews, or the default on-disk one.
    public static func make(inMemory: Bool = false) throws -> ModelContainer {
        guard !inMemory else {
            return try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            )
        }
        return try make(url: defaultStoreURL)
    }

    /// Opens (or creates) the store at `url`.
    ///
    /// If the file is incompatible or corrupt we delete it and retry ONCE: the
    /// server is the system of record, so a broken cache costs a re-sync and
    /// nothing more. A second failure is a real problem and is rethrown.
    ///
    /// THE LIMIT OF THIS VALVE (measured, 2026-09-04). It guards `open()` only,
    /// and there is one failure it structurally cannot reach: a `Codable`-blob
    /// column (`CachedMessageBody.attachments`, `CachedDraft.attachments` /
    /// `.signature`, `CachedMailbox.addresses`) whose stored shape no longer
    /// matches the DTO. The file opens fine and the schema matches; the failure
    /// happens later, when a FETCH materialises the row — and SwiftData decodes
    /// that column with `try!` (`SwiftData/DefaultStore.swift`), so it is a
    /// process-fatal trap, not a `throw`. No catch, no error type and no
    /// delete-and-retry can be reached from inside the app, and the crash repeats
    /// on every fetch of that row until the file is deleted by hand.
    ///
    /// The fix therefore has to be that decoding CANNOT fail: each of those DTOs
    /// implements a TOTAL `init(from:)` in which every field falls back to a
    /// default, so a missing, renamed or retyped key degrades one cached value
    /// instead of taking the app down. See the "CACHE-BLOB CONVENTION" note on
    /// ``Attachment`` — a new field on any of them goes in the property, the
    /// `CodingKeys` and the decode, and must have a sensible default.
    ///
    /// What remains uncovered is byte-level corruption of a blob column (bit rot,
    /// a half-written page) — that fails before any of our code runs and is fatal
    /// on any design short of storing the column as `Data` and decoding it by
    /// hand. It is accepted: SQLite's own integrity guarantees make it far rarer
    /// than the shape change above, which was a routine schema edit away.
    public static func make(url: URL) throws -> ModelContainer {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("Could not create store directory: \(error.localizedDescription, privacy: .private)")
            throw error
        }

        do {
            return try open(url)
        } catch {
            logger.warning(
                "Mail cache at \(url.lastPathComponent, privacy: .public) is unusable (\(error.localizedDescription, privacy: .private)); deleting and rebuilding from the server."
            )
            removeStoreFiles(at: url)
            do {
                return try open(url)
            } catch {
                logger.error("Mail cache could not be rebuilt: \(error.localizedDescription, privacy: .private)")
                throw error
            }
        }
    }

    private static func open(_ url: URL) throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
    }

    /// Removes the store and its SQLite sidecars.
    private static func removeStoreFiles(at url: URL) {
        let manager = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            let target = URL(fileURLWithPath: url.path + suffix)
            // No fileExists() pre-check: it is a TOCTOU race and pointless here.
            // A missing sidecar throwing ENOENT is harmless on a rebuildable cache,
            // so removal is best-effort — we simply try each path and move on.
            try? manager.removeItem(at: target)
        }
    }
}
