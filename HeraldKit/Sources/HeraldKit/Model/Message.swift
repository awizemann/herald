import Foundation

/// A message as it appears in list rows.
public nonisolated struct MessageSummary: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let threadID: String
    /// `nil` for catch-all messages not yet assigned to a mailbox.
    public let mailboxID: String?
    public let direction: MessageDirection
    public let folder: MailFolder
    public let fromAddress: String
    public let to: [String]
    public let subject: String
    public let snippet: String
    public let receivedAt: Date?
    public let sentAt: Date?
    /// Timestamp the message was marked read; `nil` means unread.
    public let readAt: Date?
    /// Timestamp the message was starred; `nil` means not starred.
    public let starredAt: Date?
    public let hasAttachments: Bool
    public let createdAt: Date

    public init(
        id: String,
        threadID: String,
        mailboxID: String?,
        direction: MessageDirection,
        folder: MailFolder,
        fromAddress: String,
        to: [String],
        subject: String,
        snippet: String,
        receivedAt: Date?,
        sentAt: Date?,
        readAt: Date?,
        starredAt: Date?,
        hasAttachments: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.threadID = threadID
        self.mailboxID = mailboxID
        self.direction = direction
        self.folder = folder
        self.fromAddress = fromAddress
        self.to = to
        self.subject = subject
        self.snippet = snippet
        self.receivedAt = receivedAt
        self.sentAt = sentAt
        self.readAt = readAt
        self.starredAt = starredAt
        self.hasAttachments = hasAttachments
        self.createdAt = createdAt
    }

    public var isUnread: Bool { readAt == nil }
    public var isStarred: Bool { starredAt != nil }
    /// Best available timestamp for sorting and display.
    public var displayDate: Date { receivedAt ?? sentAt ?? createdAt }
}

/// MIME presentation intent for an attachment part.
///
/// The server decides this (upstream 1.3.4): "a content ID does not make a part
/// inline by itself" — a PDF can carry a Content-ID and still be a download, and
/// a body image can be inline without one. Herald must never re-derive it.
public nonisolated enum AttachmentDisposition: String, Sendable, Hashable, Codable, CaseIterable {
    case attachment
    case inline
}

/// A file attached to a stored message.
public nonisolated struct Attachment: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let messageID: String
    public let filename: String
    public let contentType: String
    public let sizeBytes: Int
    /// RFC 2392 Content-ID. Present on many parts that are NOT inline.
    public let contentID: String?
    /// The server's presentation intent; the only thing that decides inline-ness.
    public let disposition: AttachmentDisposition
    public let createdAt: Date

    public init(
        id: String,
        messageID: String,
        filename: String,
        contentType: String,
        sizeBytes: Int,
        contentID: String?,
        disposition: AttachmentDisposition,
        createdAt: Date
    ) {
        self.id = id
        self.messageID = messageID
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.contentID = contentID
        self.disposition = disposition
        self.createdAt = createdAt
    }

    /// Inline parts are rendered inside the body rather than listed as downloads.
    ///
    /// Server-declared, NOT inferred from `contentID`: inferring listed inline
    /// PDFs as body images and hid real attachments from the attachment bar.
    public var isInline: Bool { disposition == .inline }
}

/// A full message, including body text, recipients and attachments.
public nonisolated struct MessageDetail: Sendable, Hashable, Codable, Identifiable {
    public let summary: MessageSummary
    public let cc: [String]
    public let bcc: [String]
    public let deliveredToAddress: String?
    public let textBody: String
    public let htmlAvailable: Bool
    /// RFC 5322 `Message-ID` header.
    public let rfcMessageID: String?
    public let inReplyTo: String?
    public let references: [String]
    public let attachments: [Attachment]

    public init(
        summary: MessageSummary,
        cc: [String],
        bcc: [String],
        deliveredToAddress: String?,
        textBody: String,
        htmlAvailable: Bool,
        rfcMessageID: String?,
        inReplyTo: String?,
        references: [String],
        attachments: [Attachment]
    ) {
        self.summary = summary
        self.cc = cc
        self.bcc = bcc
        self.deliveredToAddress = deliveredToAddress
        self.textBody = textBody
        self.htmlAvailable = htmlAvailable
        self.rfcMessageID = rfcMessageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
    }

    public var id: String { summary.id }
    public var isUnread: Bool { summary.isUnread }
    public var isStarred: Bool { summary.isStarred }
    /// Attachments the user can download (inline parts excluded).
    public var downloadableAttachments: [Attachment] { attachments.filter { !$0.isInline } }
}

/// Sanitized HTML body plus its remote-media state.
public nonisolated struct MessageHTML: Sendable, Hashable, Codable {
    public let html: String
    /// Trailing quoted history, split out by the server so the UI can collapse it.
    public let quotedHTML: String?
    public let hasRemoteImages: Bool
    public let remoteMediaTrusted: Bool

    public init(html: String, quotedHTML: String?, hasRemoteImages: Bool, remoteMediaTrusted: Bool) {
        self.html = html
        self.quotedHTML = quotedHTML
        self.hasRemoteImages = hasRemoteImages
        self.remoteMediaTrusted = remoteMediaTrusted
    }

    /// True when the UI should offer a "load remote images" affordance.
    public var needsRemoteMediaConsent: Bool { hasRemoteImages && !remoteMediaTrusted }
}
