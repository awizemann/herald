import Foundation
import SwiftData

extension MailStore {
    // MARK: - Mutation

    nonisolated static func mutate(_ row: CachedMessage, with action: MessageAction) {
        let now = Date()
        switch action {
        case .read:
            if row.readAt == nil { row.readAt = now }
        case .unread:
            row.readAt = nil
        case .star:
            if row.starredAt == nil { row.starredAt = now }
        case .unstar:
            row.starredAt = nil
        case .archive:
            row.folderRaw = MailFolder.archived.rawValue
        case .trash:
            row.folderRaw = MailFolder.trash.rawValue
        case .unarchive:
            // The server no-ops unless the message really is archived
            // (worker/features/messages/queries.ts), so the cache must too —
            // otherwise an optimistic move is reverted by the next sync.
            guard row.folderRaw == MailFolder.archived.rawValue else { return }
            row.folderRaw = Self.restoredFolder(for: row).rawValue
        case .restore:
            guard row.folderRaw == MailFolder.trash.rawValue else { return }
            row.folderRaw = Self.restoredFolder(for: row).rawValue
        }
    }

    /// Where `unarchive`/`restore` put a message, mirroring the server's
    /// `buildMessageActionPatch` (worker/features/messages/actions.ts): mail with
    /// no mailbox goes to catchall, outbound mail to sent, everything else inbox.
    ///
    /// Caveat: the server tests two DIFFERENT predicates for the catchall branch —
    /// the message route branches on `is_unassigned`, the conversation route on
    /// `mailbox_id IS NULL` (conversation-queries.ts). Herald caches only the
    /// mailbox id, so it matches the conversation route; a row with a mailbox id
    /// AND `is_unassigned = 1` would be guessed as inbox and corrected by the next
    /// sync. Caching `isUnassigned` is the real fix if that combination shows up.
    nonisolated static func restoredFolder(for row: CachedMessage) -> MailFolder {
        if row.mailboxKey.isEmpty { return .catchall }
        return row.directionRaw == MessageDirection.outbound.rawValue ? .sent : .inbox
    }

    nonisolated static func snapshot(_ row: CachedMessage) -> MessageStateSnapshot {
        MessageStateSnapshot(
            messageID: row.id,
            readAt: row.readAt,
            starredAt: row.starredAt,
            folderRaw: row.folderRaw
        )
    }

    nonisolated static func snapshot(_ row: CachedConversation) -> ConversationStateSnapshot {
        ConversationStateSnapshot(
            threadID: row.threadID,
            listFolder: row.listFolder,
            mailboxKey: row.mailboxKey,
            readAt: row.readAt,
            starredAt: row.starredAt,
            folderRaw: row.folderRaw,
            isStarred: row.isStarred,
            unreadCount: row.unreadCount
        )
    }

    // MARK: - DTO <-> row

    nonisolated static func makeMailbox(_ dto: Mailbox, accountID: String) -> CachedMailbox {
        CachedMailbox(
            id: dto.id,
            accountID: accountID,
            address: dto.address,
            addresses: dto.addresses,
            displayName: dto.displayName,
            isActive: dto.isActive,
            accessLevelRaw: dto.accessLevel?.rawValue,
            createdAt: dto.createdAt,
            updatedAt: dto.updatedAt
        )
    }

    /// Assigns only the fields that differ; returns whether anything changed.
    /// Blind reassignment would mark every row dirty on every poll and make the
    /// ``ChangeSet`` meaningless.
    nonisolated static func apply(_ dto: Mailbox, to row: CachedMailbox) -> Bool {
        var changed = false
        if row.address != dto.address { row.address = dto.address; changed = true }
        if row.addresses != dto.addresses { row.addresses = dto.addresses; changed = true }
        if row.displayName != dto.displayName { row.displayName = dto.displayName; changed = true }
        if row.isActive != dto.isActive { row.isActive = dto.isActive; changed = true }
        let accessLevel = dto.accessLevel?.rawValue
        if row.accessLevelRaw != accessLevel { row.accessLevelRaw = accessLevel; changed = true }
        if row.createdAt != dto.createdAt { row.createdAt = dto.createdAt; changed = true }
        if row.updatedAt != dto.updatedAt { row.updatedAt = dto.updatedAt; changed = true }
        return changed
    }

    /// `pending` fences the three fields an optimistic local action owns while
    /// its POST is in flight: they keep the optimistic value, everything else in
    /// the summary is accepted as usual.
    nonisolated static func apply(
        _ dto: MessageSummary,
        to row: CachedMessage,
        pending: PendingMutation?
    ) -> Bool {
        var changed = false
        if row.threadID != dto.threadID { row.threadID = dto.threadID; changed = true }
        let mailboxKey = dto.mailboxID ?? ""
        if row.mailboxKey != mailboxKey { row.mailboxKey = mailboxKey; changed = true }
        if row.directionRaw != dto.direction.rawValue { row.directionRaw = dto.direction.rawValue; changed = true }
        let folderRaw = pending?.folderRaw ?? dto.folder.rawValue
        if row.folderRaw != folderRaw { row.folderRaw = folderRaw; changed = true }
        if row.fromAddress != dto.fromAddress { row.fromAddress = dto.fromAddress; changed = true }
        if row.toAddresses != dto.to { row.toAddresses = dto.to; changed = true }
        if row.subject != dto.subject { row.subject = dto.subject; changed = true }
        if row.snippet != dto.snippet { row.snippet = dto.snippet; changed = true }
        if row.receivedAt != dto.receivedAt { row.receivedAt = dto.receivedAt; changed = true }
        if row.sentAt != dto.sentAt { row.sentAt = dto.sentAt; changed = true }
        let readAt = pending.map(\.readAt) ?? dto.readAt
        if row.readAt != readAt { row.readAt = readAt; changed = true }
        let starredAt = pending.map(\.starredAt) ?? dto.starredAt
        if row.starredAt != starredAt { row.starredAt = starredAt; changed = true }
        if row.hasAttachments != dto.hasAttachments { row.hasAttachments = dto.hasAttachments; changed = true }
        if row.createdAt != dto.createdAt { row.createdAt = dto.createdAt; changed = true }
        if row.sortDate != dto.displayDate { row.sortDate = dto.displayDate; changed = true }
        return changed
    }

    nonisolated static func apply(_ dto: ConversationSummary, to row: CachedConversation) -> Bool {
        let latest = dto.latest
        var changed = false
        if row.latestMessageID != latest.id { row.latestMessageID = latest.id; changed = true }
        if row.latestThreadID != latest.threadID { row.latestThreadID = latest.threadID; changed = true }
        let latestMailboxKey = latest.mailboxID ?? ""
        if row.latestMailboxKey != latestMailboxKey { row.latestMailboxKey = latestMailboxKey; changed = true }
        if row.directionRaw != latest.direction.rawValue {
            row.directionRaw = latest.direction.rawValue
            changed = true
        }
        if row.folderRaw != latest.folder.rawValue { row.folderRaw = latest.folder.rawValue; changed = true }
        if row.fromAddress != latest.fromAddress { row.fromAddress = latest.fromAddress; changed = true }
        if row.toAddresses != latest.to { row.toAddresses = latest.to; changed = true }
        if row.subject != latest.subject { row.subject = latest.subject; changed = true }
        if row.snippet != latest.snippet { row.snippet = latest.snippet; changed = true }
        if row.receivedAt != latest.receivedAt { row.receivedAt = latest.receivedAt; changed = true }
        if row.sentAt != latest.sentAt { row.sentAt = latest.sentAt; changed = true }
        if row.readAt != latest.readAt { row.readAt = latest.readAt; changed = true }
        if row.starredAt != latest.starredAt { row.starredAt = latest.starredAt; changed = true }
        if row.hasAttachments != latest.hasAttachments { row.hasAttachments = latest.hasAttachments; changed = true }
        if row.createdAt != latest.createdAt { row.createdAt = latest.createdAt; changed = true }
        if row.sortDate != latest.displayDate { row.sortDate = latest.displayDate; changed = true }
        if row.isStarred != dto.isStarred { row.isStarred = dto.isStarred; changed = true }
        if row.messageCount != dto.messageCount { row.messageCount = dto.messageCount; changed = true }
        if row.unreadCount != dto.unreadCount { row.unreadCount = dto.unreadCount; changed = true }
        return changed
    }

    nonisolated static func mailbox(from row: CachedMailbox) -> Mailbox {
        Mailbox(
            id: row.id,
            address: row.address,
            addresses: row.addresses,
            displayName: row.displayName,
            isActive: row.isActive,
            accessLevel: row.accessLevelRaw.flatMap(MailboxAccessLevel.init(rawValue:)),
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    nonisolated static func message(from row: CachedMessage) -> MessageSummary {
        MessageSummary(
            id: row.id,
            threadID: row.threadID,
            mailboxID: row.mailboxKey.isEmpty ? nil : row.mailboxKey,
            direction: MessageDirection(rawValue: row.directionRaw) ?? .inbound,
            folder: MailFolder(rawValue: row.folderRaw) ?? .inbox,
            fromAddress: row.fromAddress,
            to: row.toAddresses,
            subject: row.subject,
            snippet: row.snippet,
            receivedAt: row.receivedAt,
            sentAt: row.sentAt,
            readAt: row.readAt,
            starredAt: row.starredAt,
            hasAttachments: row.hasAttachments,
            createdAt: row.createdAt
        )
    }

    nonisolated static func conversation(from row: CachedConversation) -> ConversationSummary {
        ConversationSummary(
            latest: MessageSummary(
                id: row.latestMessageID,
                threadID: row.latestThreadID.isEmpty ? row.threadID : row.latestThreadID,
                mailboxID: row.latestMailboxKey.isEmpty ? nil : row.latestMailboxKey,
                direction: MessageDirection(rawValue: row.directionRaw) ?? .inbound,
                folder: MailFolder(rawValue: row.folderRaw) ?? .inbox,
                fromAddress: row.fromAddress,
                to: row.toAddresses,
                subject: row.subject,
                snippet: row.snippet,
                receivedAt: row.receivedAt,
                sentAt: row.sentAt,
                readAt: row.readAt,
                starredAt: row.starredAt,
                hasAttachments: row.hasAttachments,
                createdAt: row.createdAt
            ),
            isStarred: row.isStarred,
            messageCount: row.messageCount,
            unreadCount: row.unreadCount
        )
    }
}
