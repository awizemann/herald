import Foundation
import OSLog
import SwiftData

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "MailStore")

extension MailStore {
    // MARK: - Tombstoning

    /// Removes cached messages in exactly this (account, mailbox, folder) scope
    /// that the server no longer returns. Siblings in other folders/mailboxes
    /// are untouched — the predicate, not a post-filter, enforces that.
    @discardableResult
    public func deleteMissingMessages(
        accountID: String,
        mailboxID: String?,
        folder: MailFolder,
        keeping ids: Set<String>
    ) throws -> ChangeSet {
        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: Self.messageScopePredicate(accountID: accountID, mailboxID: mailboxID, folder: folder)
        )
        do {
            var changes = ChangeSet()
            for row in try modelContext.fetch(descriptor) where !ids.contains(row.id) {
                changes.deleted.insert(row.id)
                modelContext.delete(row)
            }
            if !changes.isEmpty { try save() }
            return changes
        } catch {
            logger.error("Message tombstoning failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Same, for one conversation listing scope. Ids are thread ids.
    @discardableResult
    public func deleteMissingConversations(
        accountID: String,
        mailboxID: String?,
        folder: ConversationFolder,
        keeping threadIDs: Set<String>
    ) throws -> ChangeSet {
        let listFolder = folder.rawValue
        let mailboxKey = mailboxID ?? ""
        let descriptor = FetchDescriptor<CachedConversation>(
            predicate: #Predicate {
                $0.accountID == accountID && $0.listFolder == listFolder && $0.mailboxKey == mailboxKey
            }
        )
        do {
            var changes = ChangeSet()
            for row in try modelContext.fetch(descriptor) where !threadIDs.contains(row.threadID) {
                changes.deleted.insert(row.threadID)
                modelContext.delete(row)
            }
            if !changes.isEmpty { try save() }
            return changes
        } catch {
            logger.error("Conversation tombstoning failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Removes ONE cached message and its body sidecar, and reports the listing
    /// scope it was in.
    ///
    /// Used for journal tombstones. Conversation rows are deliberately NOT
    /// touched here: a thread's row is re-derived from whatever messages remain,
    /// which the engine does by re-listing the affected (mailbox, folder) scope.
    @discardableResult
    public func deleteMessage(id: String, accountID: String) throws -> MessageDeletion {
        do {
            guard let row = try fetchMessage(id: id, accountID: accountID) else {
                return MessageDeletion(changes: ChangeSet(), mailboxID: nil, folder: nil)
            }
            let mailboxID = row.mailboxKey.isEmpty ? nil : row.mailboxKey
            let folder = MailFolder(rawValue: row.folderRaw)
            // The row is gone; a fence left behind would outlive everything it
            // could ever protect.
            pendingMutations[PendingKey(accountID: accountID, messageID: id)] = nil
            modelContext.delete(row)
            try modelContext.delete(
                model: CachedMessageBody.self,
                where: #Predicate { $0.accountID == accountID && $0.messageID == id }
            )
            try save()
            return MessageDeletion(changes: ChangeSet(deleted: [id]), mailboxID: mailboxID, folder: folder)
        } catch {
            logger.error("Message delete failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Drops everything cached for one mailbox — used when the server stops
    /// returning it (access revoked, mailbox deleted). Bodies go with the
    /// messages; other mailboxes are untouched.
    @discardableResult
    public func purgeMailbox(mailboxID: String, accountID: String) throws -> ChangeSet {
        do {
            var changes = ChangeSet()
            let messages = try modelContext.fetch(
                FetchDescriptor<CachedMessage>(
                    predicate: #Predicate { $0.accountID == accountID && $0.mailboxKey == mailboxID }
                )
            )
            for row in messages {
                let id = row.id
                changes.deleted.insert(id)
                pendingMutations[PendingKey(accountID: accountID, messageID: id)] = nil
                try modelContext.delete(
                    model: CachedMessageBody.self,
                    where: #Predicate { $0.accountID == accountID && $0.messageID == id }
                )
                modelContext.delete(row)
            }
            let conversations = try modelContext.fetch(
                FetchDescriptor<CachedConversation>(
                    predicate: #Predicate { $0.accountID == accountID && $0.mailboxKey == mailboxID }
                )
            )
            for row in conversations {
                changes.deleted.insert(row.threadID)
                modelContext.delete(row)
            }
            try modelContext.delete(
                model: CachedMailbox.self,
                where: #Predicate { $0.accountID == accountID && $0.id == mailboxID }
            )
            changes.deleted.insert(mailboxID)
            try save()
            return changes
        } catch {
            logger.error("Mailbox purge failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }
}
