import Foundation

/// Everything ``OutboxService`` can fail with. API failures keep their
/// ``MailAPIError`` so the UI can still tell "offline" from "expired session".
public nonisolated enum OutboxError: Error, Sendable, Hashable {
    /// An address that could not be parsed; payload is the offending address.
    case invalidRecipient(String)
    /// Send attempted with no `to`, `cc` or `bcc`.
    case noRecipients
    /// The file exceeds the per-attachment cap; nothing was uploaded.
    case attachmentTooLarge(bytes: Int, limit: Int)
    /// The draft changed on the server and re-applying our edit conflicted again.
    case draftConflict
    case api(MailAPIError)
    case fileUnreadable(URL)
}

extension OutboxError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRecipient(let address):
            "“\(address)” is not a valid email address."
        case .noRecipients:
            "Add at least one recipient before sending."
        case .attachmentTooLarge(let bytes, let limit):
            "That file is \(Self.megabytes(bytes)) — attachments are limited to \(Self.megabytes(limit))."
        case .draftConflict:
            "This draft was changed somewhere else. Reopen it to see the latest version."
        case .api(let error):
            error.errorDescription
        case .fileUnreadable(let url):
            "Herald could not read “\(url.lastPathComponent)”."
        }
    }

    private static func megabytes(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file))
    }
}
