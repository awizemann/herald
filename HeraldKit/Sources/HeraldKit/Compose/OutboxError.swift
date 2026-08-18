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
    /// The file fits on its own, but pushes the draft's total over the cap.
    case draftTooLarge(bytes: Int, limit: Int)
    /// The draft already carries as many attachments as the server accepts.
    case tooManyAttachments(limit: Int)
    /// The draft changed on the server and re-applying our edit conflicted again.
    case draftConflict
    case api(MailAPIError)
    case fileUnreadable(URL)
}

nonisolated extension OutboxError {
    /// A payload-free classifier for logs: the recipient address, the filename and
    /// the server's message are all user data, and none of them appear here.
    /// `String(describing:)` on this enum leaks every one of them.
    public var logCode: String {
        switch self {
        case .invalidRecipient: "invalid_recipient"
        case .noRecipients: "no_recipients"
        case .attachmentTooLarge(_, let limit): "attachment_too_large(limit:\(limit))"
        case .draftTooLarge(_, let limit): "draft_too_large(limit:\(limit))"
        case .tooManyAttachments(let limit): "too_many_attachments(limit:\(limit))"
        case .draftConflict: "draft_conflict"
        case .api(let error): "api(\(error.logCode))"
        case .fileUnreadable: "file_unreadable"
        }
    }
}

nonisolated extension OutboxError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRecipient(let address):
            "“\(address)” is not a valid email address."
        case .noRecipients:
            "Add at least one recipient before sending."
        case .attachmentTooLarge(let bytes, let limit):
            "That file is \(Self.megabytes(bytes)) — attachments are limited to \(Self.megabytes(limit))."
        case .draftTooLarge(let bytes, let limit):
            "That would put this message at \(Self.megabytes(bytes)) of attachments — "
                + "one message is limited to \(Self.megabytes(limit))."
        case .tooManyAttachments(let limit):
            "One message can carry \(limit) attachments. Remove one to add another."
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
