import Foundation

/// Folder a message lives in (`GET /messages?folder=`, `MessageSummary.folder`).
public nonisolated enum MailFolder: String, Sendable, Hashable, Codable, CaseIterable {
    case inbox, sent, drafts, archived, trash, catchall
}

/// Folder filter accepted by the conversation routes. Deliberately distinct from
/// ``MailFolder``: the conversation surface swaps `drafts` for `starred`.
public nonisolated enum ConversationFolder: String, Sendable, Hashable, Codable, CaseIterable {
    case inbox, sent, starred, archived, trash, catchall
}

/// Direction of a message relative to the mailbox.
public nonisolated enum MessageDirection: String, Sendable, Hashable, Codable, CaseIterable {
    case inbound, outbound
}

/// The caller's access level on a mailbox.
public nonisolated enum MailboxAccessLevel: String, Sendable, Hashable, Codable, CaseIterable {
    case read, agent, manager
}

/// Actions accepted by `POST /messages/{id}/{action}`.
public nonisolated enum MessageAction: String, Sendable, Hashable, Codable, CaseIterable {
    case read, unread, star, unstar, archive, trash
}

/// Actions accepted by `POST /conversations/{id}/{action}`.
public nonisolated enum ConversationAction: String, Sendable, Hashable, Codable, CaseIterable {
    case read, unread, star, unstar, archive, trash
}
