import Foundation
import OSLog
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "Attachments")

/// The one temporary directory attachments are staged in: pasted images on their
/// way up, downloaded attachments on their way to Quick Look or to Finder.
///
/// Everything here is disposable. The directory is emptied once per launch (on
/// first use) rather than at quit, because a crash never runs a quit handler and
/// mail attachments are the last bytes that should silently pile up in `/tmp`.
enum AttachmentScratchpad {
    /// `<temp>/com.wizemann.herald/Attachments`. Inside the sandbox container, so
    /// no entitlement is involved and nothing else can read it.
    ///
    /// Symlinks are resolved HERE, on the temp directory that always exists, so
    /// ``contains(_:)`` compares like with like: `/var/folders/…` for a path that
    /// does not exist yet against `/private/var/folders/…` for one that does is a
    /// mismatch that would quietly refuse to clean a file up.
    nonisolated static let directory: URL = FileManager.default.temporaryDirectory
        .resolvingSymlinksInPath()
        .appendingPathComponent("com.wizemann.herald", isDirectory: true)
        .appendingPathComponent("Attachments", isDirectory: true)

    /// Emptied exactly once per launch, the first time anyone stages a file.
    private nonisolated static let prepared = OSAllocatedUnfairLock(initialState: false)

    /// Creates (and, on the first call of this launch, empties) the directory.
    ///
    /// The wipe happens INSIDE the lock: two windows staging at once would
    /// otherwise let the second write its file into the directory the first is
    /// still deleting. The critical section is one `removeItem`, not I/O the user waits on.
    nonisolated static func prepare() throws {
        try prepared.withLock { done in
            let fileManager = FileManager.default
            if !done {
                try? fileManager.removeItem(at: directory)
                done = true
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
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

    /// Whether `url` really lives under the scratchpad, compared on resolved
    /// paths so `/tmp/../` games and the `/private` symlink cannot smuggle a path in.
    nonisolated static func contains(_ url: URL) -> Bool {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path
        return candidate.hasPrefix(root + "/")
    }
}
