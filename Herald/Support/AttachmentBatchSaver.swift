import AppKit
import Foundation
import HeraldKit
import OSLog

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "Attachments")

/// "Download All": one folder chooser, then every attachment copied in.
///
/// The sandbox grants user-selected read/write, so the folder the open panel
/// returns is the one place we may write; each file lands in it under a name
/// de-duplicated the way Finder does ("report 2.pdf"), never over an existing file.
enum AttachmentBatchSaver {
    /// What a batch did. Failures are per file: one attachment the server cannot
    /// produce must not cost the user the other nine.
    struct Report: Equatable {
        var saved: [URL] = []
        /// Filenames that could not be saved, in attachment order.
        var failed: [String] = []

        /// User-facing summary of a partial or total failure; `nil` when all landed.
        var failureMessage: String? {
            guard !failed.isEmpty else { return nil }
            let total = saved.count + failed.count
            let names = failed.joined(separator: ", ")
            return failed.count == total
                ? "Herald could not download the attachments: \(names)."
                : "Herald could not download \(failed.count) of \(total) attachments: \(names)."
        }
    }

    /// Asks for the destination folder. `nil` = the user cancelled.
    static func chooseFolder() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Download"
        panel.message = "Choose a folder for the attachments."
        guard await panel.begin() == .OK else { return nil }
        return panel.url
    }

    /// Fetches each attachment (through `fetch`, the staged-cache download in the
    /// app) and copies it into `folder`.
    ///
    /// - Parameter release: called after each successful fetch, once its copy is over.
    /// - Parameter progress: called with (0, total) before the first fetch, then
    ///   after each file with (finished, total).
    static func save(
        _ attachments: [Attachment],
        into folder: URL,
        fetch: (Attachment) async throws -> URL,
        release: (Attachment) async -> Void = { _ in },
        progress: (Int, Int) -> Void = { _, _ in }
    ) async -> Report {
        var report = Report()
        // Reported before the first fetch: the bar switches to "0 of N" (and
        // drops the Download All button) the moment the folder is chosen, not
        // after the first file lands — a second click in between started a
        // second batch.
        progress(0, attachments.count)
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        for (index, attachment) in attachments.enumerated() {
            do {
                let source = try await fetch(attachment)
                let copied = await Task.detached(priority: .userInitiated) { @Sendable in
                    Result { try copy(source, into: folder) }
                }.value
                // Released whether or not the copy worked: a fetched file stays
                // pinned only while it is being copied.
                await release(attachment)
                report.saved.append(try copied.get())
            } catch {
                logger.error(
                    "Attachment \(attachment.id, privacy: .public) batch save failed: \(error.localizedDescription, privacy: .private)"
                )
                report.failed.append(attachment.filename)
            }
            progress(index + 1, attachments.count)
        }
        return report
    }

    /// Copies `source` into `folder` under a free name; returns where it landed.
    nonisolated static func copy(
        _ source: URL,
        into folder: URL,
        copyFile: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    ) throws -> URL {
        let name = AttachmentSaver.sanitized(source.lastPathComponent)
        let destination = folder.appendingPathComponent(
            uniqueName(for: name) { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        )
        // Staged beside the destination and moved in: a half-written file must
        // never sit in the user's folder under the real name.
        let staging = folder.appendingPathComponent(".\(UUID().uuidString).\(destination.lastPathComponent)")
        do {
            // Inside the `do`: a copy that throws partway leaves a partial
            // staging file, which the catch removes.
            try copyFile(source, staging)
            AttachmentSaver.quarantine(staging)
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return destination
    }

    /// Finder-style de-duplication: "name.pdf", then "name 2.pdf", "name 3.pdf"…
    /// A dotfile-less name without an extension becomes "name 2".
    nonisolated static func uniqueName(for name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            if !isTaken(candidate) { return candidate }
            counter += 1
        }
    }
}
