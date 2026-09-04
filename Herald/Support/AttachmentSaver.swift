import AppKit
import Foundation
import HeraldKit
import OSLog

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "Attachments")

/// Downloads an attachment and writes it where the user points the save panel.
///
/// The app is sandboxed with user-selected read/write only, so the panel's URL is
/// the sole place we may write; filenames are sanitized because the server's
/// value is attacker-influenced.
enum AttachmentSaver {
    nonisolated static func sanitized(_ filename: String) -> String {
        let cleaned = filename.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" || scalar == "\\" { return "_" }
            if CharacterSet.controlCharacters.contains(scalar) { return "_" }
            return Character(scalar)
        }
        var name = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        // "." and ".." are directory references, not filenames.
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "attachment" : String(name.prefix(255))
    }

    /// Marks a written file as "downloaded from the internet".
    ///
    /// `LSFileQuarantineEnabled` only covers files the app creates; an atomic
    /// write replaces the file, so the flag is stamped explicitly afterwards.
    /// Best effort: a volume that cannot carry the attribute must not turn a
    /// successful save into an error.
    nonisolated static func quarantine(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeEmailAttachment as String,
            kLSQuarantineAgentNameKey as String: "Herald",
        ]
        do {
            try url.setResourceValues(values)
        } catch {
            logger.warning(
                "Could not quarantine the saved attachment: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    /// What a save attempt did. Three cases, not "an optional error message":
    /// dismissing the panel and writing the file were indistinguishable, and the
    /// caller has to tell them apart to report one and not the other.
    enum Outcome: Equatable {
        case saved
        case cancelled
        /// User-facing reason.
        case failed(String)
    }

    static func save(_ attachment: Attachment, using api: any MailAPIClient) async -> Outcome {
        let panel = NSSavePanel()
        // Staged FIRST, and pinned: the cache is the one download (previewing and
        // then saving used to fetch the same attachment twice), and its filename
        // is the one the extension correction resolved from the actual bytes — so
        // the panel proposes the name the file will really need.
        let source: URL
        do {
            source = try await AttachmentFile.shared.url(for: attachment, using: api, pinned: true)
        } catch {
            logger.error(
                "Attachment \(attachment.id, privacy: .public) download failed: \(error.localizedDescription, privacy: .private)"
            )
            return .failed(error.localizedDescription)
        }
        defer { Task { await AttachmentFile.shared.unpin(attachment.id) } }

        panel.nameFieldStringValue = source.lastPathComponent
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, let url = panel.url else { return .cancelled }

        do {
            // File I/O off the main actor; the URLs are Sendable-safe as paths.
            let destination = url
            try await Task.detached(priority: .userInitiated) { @Sendable in
                // Written beside the destination and swapped in: deleting the
                // existing file first would destroy the user's copy if the write
                // then failed halfway (an attachment can be tens of MiB).
                let staging = destination.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).\(destination.lastPathComponent)")
                try FileManager.default.copyItem(at: source, to: staging)
                quarantine(staging)
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
                    } else {
                        try FileManager.default.moveItem(at: staging, to: destination)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: staging)
                    throw error
                }
            }.value
            return .saved
        } catch {
            logger.error(
                "Attachment \(attachment.id, privacy: .public) save failed: \(error.localizedDescription, privacy: .private)"
            )
            return .failed(error.localizedDescription)
        }
    }
}
