import Foundation

/// Body of `POST /send`.
public nonisolated struct SendInput: Sendable, Hashable, Codable {
    public var from: String
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var text: String
    public var html: String?
    public var attachmentIDs: [String]
    /// Draft to consume (and delete) as part of sending.
    public var draftID: String?

    public init(
        from: String,
        to: [String],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String,
        text: String,
        html: String? = nil,
        attachmentIDs: [String] = [],
        draftID: String? = nil
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.text = text
        self.html = html
        self.attachmentIDs = attachmentIDs
        self.draftID = draftID
    }
}

/// Body of `POST /forward` (upstream 1.3.4+).
///
/// The dedicated route is the ONLY way to forward without losing the original:
/// ``SendInput`` has no forward link, so a forward sent through `POST /send`
/// carries the user's own text and nothing of the message being forwarded unless
/// a server draft with `forwardOfMessageId` happened to exist already.
///
/// `subject` omitted lets the server derive `Fwd: …`; `text` is the user's
/// authored text ONLY — the server appends the forwarded original. There is no
/// `draftId`: any composed attachments ride along as `attachmentIDs`, and the
/// compose draft is deleted separately after a successful send.
public nonisolated struct ForwardInput: Sendable, Hashable, Codable {
    /// Message being forwarded.
    public var messageID: String
    public var from: String
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String?
    public var text: String
    /// Unused by Herald's compose (plain-text bodies only); present because the
    /// route accepts it and a future rich composer will need it.
    public var html: String?
    /// Attachments the user added in compose (already uploaded to a draft).
    public var attachmentIDs: [String]
    /// When true the server copies the original message's attachments too. Herald
    /// always leaves this at the server's default — the compose window has no
    /// affordance for dropping the original's attachments.
    public var includeOriginalAttachments: Bool

    public init(
        messageID: String,
        from: String,
        to: [String],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String? = nil,
        text: String = "",
        html: String? = nil,
        attachmentIDs: [String] = [],
        includeOriginalAttachments: Bool = true
    ) {
        self.messageID = messageID
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.text = text
        self.html = html
        self.attachmentIDs = attachmentIDs
        self.includeOriginalAttachments = includeOriginalAttachments
    }
}

/// Body of `POST /reply`. Recipients default to the server's reply targets when omitted.
public nonisolated struct ReplyInput: Sendable, Hashable, Codable {
    public var messageID: String
    public var from: String
    public var to: [String]?
    public var cc: [String]?
    public var bcc: [String]?
    public var text: String
    public var html: String?
    public var attachmentIDs: [String]
    public var draftID: String?

    public init(
        messageID: String,
        from: String,
        to: [String]? = nil,
        cc: [String]? = nil,
        bcc: [String]? = nil,
        text: String,
        html: String? = nil,
        attachmentIDs: [String] = [],
        draftID: String? = nil
    ) {
        self.messageID = messageID
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.text = text
        self.html = html
        self.attachmentIDs = attachmentIDs
        self.draftID = draftID
    }
}
