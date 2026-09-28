import Foundation
import HeraldKit

/// Every unread count the sidebar and the Dock draw, derived in memory from
/// ONE store read of the account's unread conversation rows
/// (``MailStore/unreadConversationKeys(accountID:)``).
///
/// Every count is of DISTINCT threads. A thread with messages in two mailboxes
/// has a conversation row under each, so a domain, All domains or the badge
/// that summed its mailboxes' numbers counted it twice — while opening the
/// listing (which dedupes by thread) showed it once. A single mailbox cannot
/// hold two rows of one thread in one folder (`#Unique`), so its count is the
/// same either way.
///
/// Pure and `nonisolated`: built off the main actor, assertable without a
/// store.
nonisolated struct UnreadTally: Equatable, Sendable {
    /// Unread per sidebar folder of the scope on screen; zero counts left out.
    var byFolder: [ConversationFolder: Int] = [:]
    /// Inbox unread per mailbox; zero counts left out.
    var byMailbox: [Mailbox.ID: Int] = [:]
    /// Inbox unread per domain; zero counts left out.
    var byDomain: [MailDomain.ID: Int] = [:]
    var allDomains = 0
    var badge = 0

    init() {}

    /// - Parameters:
    ///   - scopeIDs, allDomainIDs, badgeIDs: resolved mailbox sets, `nil` for
    ///     "every row" (``MailViewModel/mailboxIDs(for:)``'s contract).
    ///   - mailboxIDs: the mailboxes that get a row count of their own.
    init(
        keys: [UnreadConversationKey],
        scopeIDs: Set<String>?,
        folders: [ConversationFolder],
        mailboxIDs: [Mailbox.ID],
        domains: [MailDomain],
        allDomainIDs: Set<String>?,
        badgeIDs: Set<String>?
    ) {
        let inbox = keys.filter { $0.counts(in: .inbox) }

        var threadsByMailbox: [String: Set<String>] = [:]
        for key in inbox { threadsByMailbox[key.mailboxKey, default: []].insert(key.threadID) }
        for id in mailboxIDs {
            if let count = threadsByMailbox[id]?.count, count > 0 { byMailbox[id] = count }
        }
        for domain in domains {
            var threads: Set<String> = []
            for id in domain.mailboxIDs { threads.formUnion(threadsByMailbox[id] ?? []) }
            if !threads.isEmpty { byDomain[domain.id] = threads.count }
        }

        for folder in folders {
            let rows = folder == .inbox ? inbox : keys.filter { $0.counts(in: folder) }
            let count = Self.distinctThreads(rows, in: scopeIDs)
            if count > 0 { byFolder[folder] = count }
        }

        allDomains = Self.distinctThreads(inbox, in: allDomainIDs)
        badge = badgeIDs == allDomainIDs ? allDomains : Self.distinctThreads(inbox, in: badgeIDs)
    }

    static func distinctThreads(_ keys: [UnreadConversationKey], in mailboxIDs: Set<String>?) -> Int {
        var threads: Set<String> = []
        for key in keys where mailboxIDs?.contains(key.mailboxKey) ?? true {
            threads.insert(key.threadID)
        }
        return threads.count
    }
}
