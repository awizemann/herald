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

    /// Returns an error message for the UI, or `nil` on success/cancel.
    static func save(_ attachment: Attachment, using api: any MailAPIClient) async -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sanitized(attachment.filename)
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, let url = panel.url else { return nil }

        do {
            let payload = try await api.attachmentData(id: attachment.id)
            // File I/O off the main actor; the panel URL is Sendable-safe as a path.
            let destination = url
            try await Task.detached(priority: .userInitiated) { @Sendable [payload] in
                try payload.data.write(to: destination, options: .atomic)
            }.value
            return nil
        } catch {
            logger.error(
                "Attachment \(attachment.id, privacy: .public) save failed: \(error.localizedDescription, privacy: .public)"
            )
            return error.localizedDescription
        }
    }
}
