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
    /// The server will not take another attempt at this message right now, and
    /// re-sending would be the wrong thing to do. See ``SendHold``.
    case sendOnHold(SendHold)
    case api(MailAPIError)
    case fileUnreadable(URL)
}

/// Why a send may not be attempted again — the two 503s upstream 1.4.0 added.
///
/// Both are "the server is mid-something, and a second POST is not the answer",
/// but they differ in what happened to the message, which is why the compose
/// window treats them differently (see `ComposeViewModel.sendHold`).
public nonisolated enum SendHold: String, Sendable, Hashable, CaseIterable {
    /// `SEND_RECOVERY_UNAVAILABLE` — the mail was ACCEPTED but its delivery
    /// outcome could not be recorded. Upstream's own words: "Accepted mail needs
    /// storage recovery. Do not send it again."
    case recovering
    /// `SEND_STORAGE_NOT_READY` — the post-deploy triggers do not exist yet, so
    /// nothing was accepted. Sending is unavailable until the update finishes.
    case storageNotReady

    /// Maps a server error code, or `nil` when it is some other failure.
    public static func code(_ code: String) -> SendHold? {
        switch code.uppercased() {
        case "SEND_RECOVERY_UNAVAILABLE": .recovering
        case "SEND_STORAGE_NOT_READY": .storageNotReady
        default: nil
        }
    }
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
        case .sendOnHold(let hold): "send_on_hold(\(hold.rawValue))"
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
        case .sendOnHold(.recovering):
            "The server accepted this message but has not finished recording it. "
                + "Do not send it again — it will appear in Sent once the server catches up."
        case .sendOnHold(.storageNotReady):
            "Sending is unavailable until the server finishes a database update. "
                + "Your message is kept here — do not send it again yet."
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
