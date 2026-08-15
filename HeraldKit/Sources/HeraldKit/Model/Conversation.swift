import Foundation

/// A thread, represented by its newest message plus thread-level counters.
public nonisolated struct ConversationSummary: Sendable, Hashable, Codable, Identifiable {
    /// Newest message in the thread; also the source of subject/sender/date.
    public let latest: MessageSummary
    public let isStarred: Bool
    public let messageCount: Int
    public let unreadCount: Int

    public init(latest: MessageSummary, isStarred: Bool, messageCount: Int, unreadCount: Int) {
        self.latest = latest
        self.isStarred = isStarred
        self.messageCount = messageCount
        self.unreadCount = unreadCount
    }

    /// Threads are identified by thread id, not by the latest message id.
    public var id: String { latest.threadID }
    public var isUnread: Bool { unreadCount > 0 }
}

/// One page of conversations. `nextCursor == nil` means the last page.
public nonisolated struct ConversationPage: Sendable, Hashable, Codable {
    public let conversations: [ConversationSummary]
    public let nextCursor: String?
    /// Total matching threads, when the server chose to compute it.
    public let totalCount: Int?

    public init(conversations: [ConversationSummary], nextCursor: String?, totalCount: Int?) {
        self.conversations = conversations
        self.nextCursor = nextCursor
        self.totalCount = totalCount
    }

    public var hasMore: Bool { nextCursor != nil }
}

/// Result of a conversation-level action.
public nonisolated struct ConversationActionResult: Sendable, Hashable, Codable {
    public let threadID: String
    /// Number of messages the action changed.
    public let affected: Int

    public init(threadID: String, affected: Int) {
        self.threadID = threadID
        self.affected = affected
    }
}
