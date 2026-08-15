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
