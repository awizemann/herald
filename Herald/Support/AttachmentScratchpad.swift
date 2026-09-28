import Darwin
import Foundation
import OSLog
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "Attachments")

/// Where attachment bytes live on disk: `Application Support/<bundle id>/`,
/// inside the sandbox container.
///
/// Why not the temp directory any more (2026-09-28): the old scratchpad
/// (`<tmp>/com.wizemann.herald/Attachments`) was EMPTIED WHOLESALE by the first
/// stage of every launch. Every process with the same bundle id shares the
/// container — the unit-test host is the Debug app itself — so a test run (or a
/// second copy) wiped the file a live Quick Look panel was showing, and the panel
/// fell over. Nothing here is ever wiped wholesale now: a process deletes only
/// what it staged, plus entries old enough to be nobody's (``pruneStale``).
enum AttachmentStorage {
    /// `Application Support/<bundle id>`. The container is per bundle id already;
    /// the bundle-id component keeps the layout conventional and Debug/Release apart
    /// should the app ever run unsandboxed.
    nonisolated static let root: URL = {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.resolvingSymlinksInPath()
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.wizemann.herald", isDirectory: true)
    }()

    /// Downloaded (received) attachments: `<root>/Attachments/<account id>/<attachment id>/<filename>`.
    nonisolated static let attachments = root.appendingPathComponent("Attachments", isDirectory: true)

    /// Compose-side copies and pasted images: `<root>/Compose/<uuid>/<filename>`.
    nonisolated static let compose = root.appendingPathComponent("Compose", isDirectory: true)

    /// The pre-2026-09-28 temp scratchpad, removed once per launch.
    nonisolated static let legacyTemp = FileManager.default.temporaryDirectory
        .resolvingSymlinksInPath()
        .appendingPathComponent("com.wizemann.herald", isDirectory: true)

    /// Anything not touched for this long belongs to no live panel, window or
    /// drag, in this process or another one.
    nonisolated static let staleAge: TimeInterval = 2 * 24 * 60 * 60

    /// Deletes the direct children of `directory` (recursively descending
    /// `depth` levels) whose modification date is older than `age`. Stale
    /// entries are always safe to delete: the store is a rebuildable cache.
    nonisolated static func pruneStale(in directory: URL, olderThan age: TimeInterval, depth: Int = 0, now: Date = .now) {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        ) else { return }
        for child in children {
            if depth > 0 {
                pruneStale(in: child, olderThan: age, depth: depth - 1, now: now)
                // An account folder left empty goes too.
                if (try? fileManager.contentsOfDirectory(atPath: child.path))?.isEmpty == true {
                    try? fileManager.removeItem(at: child)
                }
                continue
            }
            let modified = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > age {
                try? fileManager.removeItem(at: child)
            }
        }
    }

    /// Whether `url` really lives under `directory`, compared on resolved paths
    /// so `../` games and the `/private` symlink cannot smuggle a path in.
    nonisolated static func url(_ url: URL, isInside directory: URL) -> Bool {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path
        return candidate.hasPrefix(root + "/")
    }

    /// The user's real `~/Downloads`. `FileManager`'s `.downloadsDirectory`
    /// answers the SANDBOX container's copy; the panels want the real folder,
    /// which they are entitled to show.
    nonisolated static var downloadsDirectory: URL {
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
                .appendingPathComponent("Downloads", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }
}

/// Compose-side staging: pasted images on their way up and the composer's local
/// copies of files the user attached. Lives in ``AttachmentStorage/compose``.
///
/// Each file sits in its own UUID folder, deleted by its owner (Remove, window
/// close, a finished upload). There is no launch-time wipe — that deleted other
/// processes' live files — only a once-per-launch prune of folders untouched
/// for ``AttachmentStorage/staleAge`` (what a crash leaves behind).
enum AttachmentScratchpad {
    nonisolated static var directory: URL { AttachmentStorage.compose }

    /// Pruned exactly once per launch, the first time anyone stages a file.
    private nonisolated static let prepared = OSAllocatedUnfairLock(initialState: false)

    /// Creates the directory; on the first call of this launch also prunes stale
    /// folders and removes the legacy temp scratchpad.
    nonisolated static func prepare() throws {
        try prepared.withLock { done in
            if !done {
                done = true
                AttachmentStorage.pruneStale(in: directory, olderThan: AttachmentStorage.staleAge)
                try? FileManager.default.removeItem(at: AttachmentStorage.legacyTemp)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Writes `data` into a fresh subdirectory, so two files that sanitize to the
    /// same name cannot overwrite each other.
    ///
    /// - Parameter filename: caller-supplied and therefore attacker-influenced
    ///   (a pasted or server-provided name); sanitized here, never trusted.
    nonisolated static func stage(_ data: Data, filename: String) throws -> URL {
        try prepare()
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(AttachmentSaver.sanitized(filename))
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Deletes a staged file and its wrapper directory. Refuses anything outside
    /// the scratchpad: the same call site also handles files the USER picked, and
    /// deleting one of those would destroy the original.
    nonisolated static func discard(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        // `contains` on the folder too: a file sitting directly in the root would
        // otherwise make this delete every OTHER window's staged upload with it.
        guard contains(url), contains(folder) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            logger.warning("Could not clear a staged attachment: \(error.localizedDescription, privacy: .private)")
        }
    }

    nonisolated static func contains(_ url: URL) -> Bool {
        AttachmentStorage.url(url, isInside: directory)
    }
}
