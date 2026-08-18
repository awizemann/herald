import Foundation

/// A file already uploaded to a draft.
public nonisolated struct DraftAttachment: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let filename: String
    public let contentType: String
    public let sizeBytes: Int

    public init(id: String, filename: String, contentType: String, sizeBytes: Int) {
        self.id = id
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
    }
}

/// The writable fields of a draft (`POST /drafts`, `PATCH /drafts/{id}`).
///
/// `version` is the optimistic-concurrency token: send the version you loaded and
/// the server rejects the update with 409 if someone else saved in between.
public nonisolated struct DraftInput: Sendable, Hashable, Codable {
    public var mailboxID: String?
    public var replyToMessageID: String?
    public var forwardOfMessageID: String?
    public var from: String
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var text: String
    public var html: String
    public var version: Int?

    public init(
        mailboxID: String? = nil,
        replyToMessageID: String? = nil,
        forwardOfMessageID: String? = nil,
        from: String = "",
        to: [String] = [],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String = "",
        text: String = "",
        html: String = "",
        version: Int? = nil
    ) {
        self.mailboxID = mailboxID
        self.replyToMessageID = replyToMessageID
        self.forwardOfMessageID = forwardOfMessageID
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.text = text
        self.html = html
        self.version = version
    }
}

/// A stored draft.
public nonisolated struct Draft: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let version: Int
    public let updatedAt: Date
    public let attachments: [DraftAttachment]
    public let content: DraftInput

    public init(id: String, version: Int, updatedAt: Date, attachments: [DraftAttachment], content: DraftInput) {
        self.id = id
        self.version = version
        self.updatedAt = updatedAt
        self.attachments = attachments
        self.content = content
    }

    /// The content to send back on the next `PATCH`, stamped with the current version.
    public var editableContent: DraftInput {
        var input = content
        input.version = version
        return input
    }
}

/// One row of the Drafts folder, as the list renders it.
///
/// The list never sees a `@Model` and never needs the body: this is the whole
/// contract between ``MailStore`` and the drafts list. Opening a draft asks the
/// store for the full ``Draft`` separately, so the row stays cheap.
public nonisolated struct DraftSummary: Sendable, Hashable, Identifiable {
    public let id: String
    public let mailboxID: String?
    /// `to`, in the order the user typed them. The row shows these, or a
    /// placeholder when the draft has no recipients yet.
    public let recipients: [String]
    public let subject: String
    /// First line or so of the body, whitespace-collapsed — the row's preview.
    public let snippet: String
    public let updatedAt: Date
    public let hasAttachments: Bool

    public init(
        id: String,
        mailboxID: String?,
        recipients: [String],
        subject: String,
        snippet: String,
        updatedAt: Date,
        hasAttachments: Bool
    ) {
        self.id = id
        self.mailboxID = mailboxID
        self.recipients = recipients
        self.subject = subject
        self.snippet = snippet
        self.updatedAt = updatedAt
        self.hasAttachments = hasAttachments
    }

    /// How many characters of the body a row preview keeps. Long enough for two
    /// rendered lines, short enough that a 100 KB draft body never reaches a view.
    static let snippetLength = 200

    /// Collapses the body's whitespace into a single-line preview. Done at map
    /// time, inside the store actor, so a big body is never handed to the main
    /// actor just to be truncated there.
    public nonisolated static func snippet(from body: String) -> String {
        let collapsed = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > snippetLength else { return collapsed }
        return String(collapsed.prefix(snippetLength)) + "…"
    }
}
