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
        [CachedMailbox.self, CachedConversation.self, CachedMessage.self, CachedMessageBody.self]
    }

    /// Canonical schema. No `VersionedSchema`: the store is a rebuildable cache.
    public static var schema: Schema { Schema(models) }

    /// Default on-disk location (Application Support), safe to delete at any time.
    public static var defaultStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Herald", isDirectory: true)
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
    public static func make(url: URL) throws -> ModelContainer {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("Could not create store directory: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        do {
            return try open(url)
        } catch {
            logger.warning(
                "Mail cache at \(url.lastPathComponent, privacy: .public) is unusable (\(error.localizedDescription, privacy: .public)); deleting and rebuilding from the server."
            )
            removeStoreFiles(at: url)
            do {
                return try open(url)
            } catch {
                logger.error("Mail cache could not be rebuilt: \(error.localizedDescription, privacy: .public)")
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
            guard manager.fileExists(atPath: target.path) else { continue }
            do {
                try manager.removeItem(at: target)
            } catch {
                logger.error(
                    "Could not delete \(target.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
