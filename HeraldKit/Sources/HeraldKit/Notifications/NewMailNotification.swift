import Foundation

/// One banner Herald wants to show, as a value.
///
/// Deliberately free of `UserNotifications`: the decision half of new-mail
/// notifications is pure and testable, and the app target owns the one adapter
/// that turns this into a `UNNotificationRequest`.
public nonisolated struct NewMailNotification: Sendable, Hashable, Identifiable {
    /// Stable request identifier. Posting the same id twice REPLACES the banner
    /// rather than stacking a second one.
    public let id: String
    public let title: String
    public let subtitle: String
    public let body: String
    /// Which account the mail landed in — the routing target of a click.
    public let accountID: String
    /// The conversation to select on click. `nil` for a coalesced burst, which
    /// can only select the account.
    public let threadID: String?
    public let messageID: String?
    /// How many messages this banner stands for (1 unless coalesced).
    public let messageCount: Int

    public init(
        id: String,
        title: String,
        subtitle: String,
        body: String,
        accountID: String,
        threadID: String?,
        messageID: String?,
        messageCount: Int
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.accountID = accountID
        self.threadID = threadID
        self.messageID = messageID
        self.messageCount = messageCount
    }

    public var isCoalesced: Bool { messageCount > 1 }

    // MARK: - userInfo

    public static let accountIDKey = "com.wizemann.herald.accountID"
    public static let threadIDKey = "com.wizemann.herald.threadID"
    public static let messageIDKey = "com.wizemann.herald.messageID"

    /// `[String: String]` rather than `[AnyHashable: Any]`: the payload crosses
    /// into a framework callback, so everything in it stays Sendable.
    public var userInfo: [String: String] {
        var info = [Self.accountIDKey: accountID]
        if let threadID { info[Self.threadIDKey] = threadID }
        if let messageID { info[Self.messageIDKey] = messageID }
        return info
    }

    /// The inverse of ``userInfo`` — what a click hands back to the app.
    /// `nil` when the payload carries no account, i.e. it is not ours.
    public static func route(from userInfo: [String: String]) -> NewMailRoute? {
        guard let accountID = userInfo[accountIDKey], !accountID.isEmpty else { return nil }
        return NewMailRoute(
            accountID: accountID,
            threadID: userInfo[threadIDKey],
            messageID: userInfo[messageIDKey]
        )
    }
}

/// Where a clicked notification wants the UI to go.
public nonisolated struct NewMailRoute: Sendable, Hashable {
    public let accountID: String
    public let threadID: String?
    public let messageID: String?

    public init(accountID: String, threadID: String?, messageID: String?) {
        self.accountID = accountID
        self.threadID = threadID
        self.messageID = messageID
    }
}

/// The notification centre, behind a protocol so the decision logic is testable
/// without `UNUserNotificationCenter` (which needs a real signed bundle and
/// prompts the user).
///
/// `nonisolated` because the conforming adapter is a value type used from an
/// actor — see "Herald Concurrency Rules".
public nonisolated protocol NewMailNotificationPosting: Sendable {
    /// Asks for banner permission. Returns whether Herald may post.
    /// Implementations must NOT throw: a denial is an ordinary answer.
    func requestAuthorization() async -> Bool
    func post(_ notification: NewMailNotification) async
}
