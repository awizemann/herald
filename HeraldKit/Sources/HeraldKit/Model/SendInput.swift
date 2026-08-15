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
