import Foundation

/// One page of `GET /messages`.
///
/// `nextCursor` is read out of the RFC 8288 `Link: <url>; rel="next"` response
/// header (the `cursor` query item of that URL); the header is absent on the
/// last page, and on a server that predates pagination it never appears at all,
/// so `nil` also means "this server does not paginate".
public nonisolated struct MessagePage: Sendable, Hashable {
    public let messages: [MessageSummary]
    public let nextCursor: String?

    public init(messages: [MessageSummary], nextCursor: String?) {
        self.messages = messages
        self.nextCursor = nextCursor
    }

    public var hasMore: Bool { nextCursor != nil }
}

/// One entry in the server's durable message-change journal.
///
/// A `delete` carries its own `mailboxID` because the message row is already
/// gone server-side — the tombstone is authorized (and scoped) by the mailbox id
/// the journal stored with it. Since upstream 1.3.4 that id is NULLABLE: mail the
/// owner holds with no mailbox assignment tombstones with `mailboxId: null`, which
/// addresses the UNASSIGNED listing scope (the one cached rows carry as
/// `mailboxKey == ""`) — not "every mailbox". The all-folders fan-out is a
/// separate condition, driven by an unknown FOLDER (see `SyncEngine`).
public nonisolated enum MessageChange: Sendable, Hashable {
    case upsert(MessageSummary)
    case delete(messageID: String, mailboxID: String?)

    public var messageID: String {
        switch self {
        case .upsert(let summary): summary.id
        case .delete(let messageID, _): messageID
        }
    }

    public var mailboxID: String? {
        switch self {
        case .upsert(let summary): summary.mailboxID
        case .delete(_, let mailboxID): mailboxID
        }
    }
}

/// One page of `GET /changes`.
///
/// `nextCursor` is NOT optional: a page always reports where to resume, and a
/// cursor-less request is a CHECKPOINT — no history, empty `changes`, and the
/// journal's current high-water cursor.
public nonisolated struct ChangePage: Sendable, Hashable {
    public let changes: [MessageChange]
    public let nextCursor: String
    public let hasMore: Bool

    public init(changes: [MessageChange], nextCursor: String, hasMore: Bool) {
        self.changes = changes
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}
