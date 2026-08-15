import Foundation
import OSLog
import SwiftData

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "MailStore")

/// Pre-mutation state of one cached message, so an optimistic action can be
/// reverted exactly (not "guessed back") when the server rejects it.
public nonisolated struct MessageStateSnapshot: Sendable, Hashable {
    public let messageID: String
    public let readAt: Date?
    public let starredAt: Date?
    public let folderRaw: String
}

/// Pre-mutation state of one cached conversation row.
public nonisolated struct ConversationStateSnapshot: Sendable, Hashable {
    public let threadID: String
    public let listFolder: String
    public let mailboxKey: String
    public let readAt: Date?
    public let starredAt: Date?
    public let folderRaw: String
    public let isStarred: Bool
    public let unreadCount: Int
}

/// Everything needed to undo one optimistic local action.
public nonisolated struct LocalActionUndo: Sendable, Hashable {
    public var accountID: String
    public var messages: [MessageStateSnapshot]
    public var conversations: [ConversationStateSnapshot]

    public init(
        accountID: String,
        messages: [MessageStateSnapshot] = [],
        conversations: [ConversationStateSnapshot] = []
    ) {
        self.accountID = accountID
        self.messages = messages
        self.conversations = conversations
    }

    public var isEmpty: Bool { messages.isEmpty && conversations.isEmpty }
}

/// The ONLY place `@Model` is touched.
///
/// Every method takes and returns Sendable value DTOs; no `PersistentModel`
/// ever crosses the actor boundary. Filtering happens in `#Predicate` inside
/// the actor — never "fetch everything, filter in Swift".
@ModelActor
public actor MailStore {
    /// Convenience for tests and previews.
    public static func inMemory() throws -> MailStore {
        MailStore(modelContainer: try MailStoreContainer.make(inMemory: true))
    }

    // MARK: - Reads

    public func mailboxes(accountID: String) throws -> [Mailbox] {
        var descriptor = FetchDescriptor<CachedMailbox>(
            predicate: #Predicate { $0.accountID == accountID },
            sortBy: [SortDescriptor(\.displayName, order: .forward)]
        )
        descriptor.fetchLimit = nil
        do {
            return try modelContext.fetch(descriptor).map(Self.mailbox(from:))
        } catch {
            logger.error("Mailbox fetch failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Newest-first page of cached conversations for a listing scope.
    ///
    /// `mailboxID == nil` means "every mailbox"; otherwise the scope is exact.
    public func conversations(
        accountID: String,
        mailboxID: String?,
        folder: ConversationFolder,
        limit: Int = 100,
        offset: Int = 0
    ) throws -> [ConversationSummary] {
        let listFolder = folder.rawValue
        let predicate: Predicate<CachedConversation>
        if let mailboxID {
            predicate = #Predicate {
                $0.accountID == accountID && $0.listFolder == listFolder && $0.mailboxKey == mailboxID
            }
        } else {
            predicate = #Predicate { $0.accountID == accountID && $0.listFolder == listFolder }
        }
        var descriptor = FetchDescriptor<CachedConversation>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.sortDate, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        do {
            return try modelContext.fetch(descriptor).map(Self.conversation(from:))
        } catch {
            logger.error("Conversation fetch failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Every cached message in a thread, oldest first (reading order).
    public func messages(accountID: String, threadID: String) throws -> [MessageSummary] {
        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { $0.accountID == accountID && $0.threadID == threadID },
            sortBy: [SortDescriptor(\.sortDate, order: .forward)]
        )
        do {
            return try modelContext.fetch(descriptor).map(Self.message(from:))
        } catch {
            logger.error("Thread fetch failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Newest-first page of cached messages in a folder scope.
    public func messages(
        accountID: String,
        mailboxID: String?,
        folder: MailFolder,
        limit: Int = 100,
        offset: Int = 0
    ) throws -> [MessageSummary] {
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: Self.messageScopePredicate(accountID: accountID, mailboxID: mailboxID, folder: folder),
            sortBy: [SortDescriptor(\.sortDate, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        do {
            return try modelContext.fetch(descriptor).map(Self.message(from:))
        } catch {
            logger.error("Folder fetch failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public func message(id: String) throws -> MessageSummary? {
        do {
            return try fetchMessage(id: id).map(Self.message(from:))
        } catch {
            logger.error("Message fetch failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Bodies (sidecar)

    public func cachedBody(messageID: String) throws -> CachedBody? {
        var descriptor = FetchDescriptor<CachedMessageBody>(
            predicate: #Predicate { $0.messageID == messageID }
        )
        descriptor.fetchLimit = 1
        do {
            guard let row = try modelContext.fetch(descriptor).first else { return nil }
            return CachedBody(
                messageID: row.messageID,
                textBody: row.textBody,
                html: row.html,
                fetchedAt: row.fetchedAt
            )
        } catch {
            logger.error("Body fetch failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    @discardableResult
    public func storeBody(
        messageID: String,
        accountID: String,
        textBody: String,
        html: String?,
        fetchedAt: Date = Date()
    ) throws -> ChangeSet {
        var descriptor = FetchDescriptor<CachedMessageBody>(
            predicate: #Predicate { $0.messageID == messageID }
        )
        descriptor.fetchLimit = 1
        do {
            guard let existing = try modelContext.fetch(descriptor).first else {
                modelContext.insert(
                    CachedMessageBody(
                        messageID: messageID,
                        accountID: accountID,
                        textBody: textBody,
                        html: html,
                        fetchedAt: fetchedAt
                    )
                )
                try save()
                return ChangeSet(inserted: [messageID])
            }
            var changed = false
            if existing.textBody != textBody { existing.textBody = textBody; changed = true }
            if existing.html != html { existing.html = html; changed = true }
            guard changed else { return ChangeSet() }
            existing.fetchedAt = fetchedAt
            try save()
            return ChangeSet(updated: [messageID])
        } catch {
            logger.error("Body store failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Upserts (idempotent, change-detecting)

    /// Inserts new mailboxes and updates only the fields that actually differ.
    @discardableResult
    public func upsertMailboxes(_ mailboxes: [Mailbox], accountID: String) throws -> ChangeSet {
        guard !mailboxes.isEmpty else { return ChangeSet() }
        var changes = ChangeSet()
        do {
            let existing = try fetchMailboxes(accountID: accountID, ids: mailboxes.map(\.id))
            for dto in mailboxes {
                guard let row = existing[dto.id] else {
                    modelContext.insert(Self.makeMailbox(dto, accountID: accountID))
                    changes.inserted.insert(dto.id)
                    continue
                }
                if Self.apply(dto, to: row) { changes.updated.insert(dto.id) }
            }
            if !changes.isEmpty { try save() }
            return changes
        } catch {
            logger.error("Mailbox upsert failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Upserts one listing scope's conversations. Ids in the ``ChangeSet`` are thread ids.
    @discardableResult
    public func upsertConversations(
        _ conversations: [ConversationSummary],
        accountID: String,
        mailboxID: String?,
        folder: ConversationFolder
    ) throws -> ChangeSet {
        guard !conversations.isEmpty else { return ChangeSet() }
        let listFolder = folder.rawValue
        let mailboxKey = mailboxID ?? ""
        var changes = ChangeSet()
        do {
            let existing = try fetchConversations(
                accountID: accountID,
                listFolder: listFolder,
                mailboxKey: mailboxKey,
                threadIDs: conversations.map(\.id)
            )
            for dto in conversations {
                guard let row = existing[dto.id] else {
                    let row = CachedConversation(
                        threadID: dto.id,
                        accountID: accountID,
                        listFolder: listFolder,
                        mailboxKey: mailboxKey
                    )
                    _ = Self.apply(dto, to: row)
                    modelContext.insert(row)
                    changes.inserted.insert(dto.id)
                    continue
                }
                if Self.apply(dto, to: row) { changes.updated.insert(dto.id) }
            }
            if !changes.isEmpty { try save() }
            return changes
        } catch {
            logger.error("Conversation upsert failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Upserts message summaries. A message's identity is its server id, so the
    /// scope arguments are not needed — a message that moved folder is an update.
    @discardableResult
    public func upsertMessages(_ messages: [MessageSummary], accountID: String) throws -> ChangeSet {
        guard !messages.isEmpty else { return ChangeSet() }
        var changes = ChangeSet()
        do {
            let existing = try fetchMessages(accountID: accountID, ids: messages.map(\.id))
            for dto in messages {
                guard let row = existing[dto.id] else {
                    let row = CachedMessage(id: dto.id, accountID: accountID)
                    _ = Self.apply(dto, to: row)
                    modelContext.insert(row)
                    changes.inserted.insert(dto.id)
                    continue
                }
                if Self.apply(dto, to: row) { changes.updated.insert(dto.id) }
            }
            if !changes.isEmpty { try save() }
            return changes
        } catch {
            logger.error("Message upsert failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

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
            logger.error("Message tombstoning failed: \(error.localizedDescription, privacy: .public)")
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
            logger.error("Conversation tombstoning failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Drops every cached row for an account (sign-out, or a forced rebuild).
    public func deleteAll(accountID: String) throws {
        do {
            try modelContext.delete(model: CachedMessageBody.self, where: #Predicate { $0.accountID == accountID })
            try modelContext.delete(model: CachedMessage.self, where: #Predicate { $0.accountID == accountID })
            try modelContext.delete(model: CachedConversation.self, where: #Predicate { $0.accountID == accountID })
            try modelContext.delete(model: CachedMailbox.self, where: #Predicate { $0.accountID == accountID })
            try save()
        } catch {
            logger.error("Cache purge failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Optimistic local actions

    /// Applies a message action locally, right now, and returns the undo token.
    /// An empty undo means the message is not cached (nothing to revert).
    public func applyLocalAction(
        _ action: MessageAction,
        messageID: String,
        accountID: String
    ) throws -> LocalActionUndo {
        do {
            guard let row = try fetchMessage(id: messageID) else {
                logger.warning("Local action \(action.rawValue, privacy: .public) on uncached message")
                return LocalActionUndo(accountID: accountID)
            }
            let threadID = row.threadID
            let conversationRows = try fetchConversationRows(accountID: accountID, threadID: threadID)
            let undo = LocalActionUndo(
                accountID: accountID,
                messages: [Self.snapshot(row)],
                conversations: conversationRows.map(Self.snapshot)
            )
            Self.mutate(row, with: action)
            try refreshConversationRows(conversationRows, accountID: accountID, threadID: threadID)
            try save()
            return undo
        } catch {
            logger.error("Local message action failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Applies a conversation action to every cached message in the thread.
    public func applyLocalAction(
        _ action: ConversationAction,
        threadID: String,
        accountID: String
    ) throws -> LocalActionUndo {
        do {
            let messageRows = try fetchThreadMessages(accountID: accountID, threadID: threadID)
            let conversationRows = try fetchConversationRows(accountID: accountID, threadID: threadID)
            guard !messageRows.isEmpty || !conversationRows.isEmpty else {
                logger.warning("Local action \(action.rawValue, privacy: .public) on uncached thread")
                return LocalActionUndo(accountID: accountID)
            }
            let undo = LocalActionUndo(
                accountID: accountID,
                messages: messageRows.map(Self.snapshot),
                conversations: conversationRows.map(Self.snapshot)
            )
            let messageAction = MessageAction(rawValue: action.rawValue)
            for row in messageRows {
                if let messageAction { Self.mutate(row, with: messageAction) }
            }
            try refreshConversationRows(conversationRows, accountID: accountID, threadID: threadID)
            try save()
            return undo
        } catch {
            logger.error("Local conversation action failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Restores the exact pre-action state. Used when the server rejects the action.
    public func revertLocalAction(_ undo: LocalActionUndo) throws {
        guard !undo.isEmpty else { return }
        do {
            let byID = try fetchMessages(accountID: undo.accountID, ids: undo.messages.map(\.messageID))
            for snapshot in undo.messages {
                guard let row = byID[snapshot.messageID] else { continue }
                row.readAt = snapshot.readAt
                row.starredAt = snapshot.starredAt
                row.folderRaw = snapshot.folderRaw
            }
            for snapshot in undo.conversations {
                let threadID = snapshot.threadID
                let listFolder = snapshot.listFolder
                let mailboxKey = snapshot.mailboxKey
                let accountID = undo.accountID
                var descriptor = FetchDescriptor<CachedConversation>(
                    predicate: #Predicate {
                        $0.accountID == accountID
                            && $0.threadID == threadID
                            && $0.listFolder == listFolder
                            && $0.mailboxKey == mailboxKey
                    }
                )
                descriptor.fetchLimit = 1
                guard let row = try modelContext.fetch(descriptor).first else { continue }
                row.readAt = snapshot.readAt
                row.starredAt = snapshot.starredAt
                row.folderRaw = snapshot.folderRaw
                row.isStarred = snapshot.isStarred
                row.unreadCount = snapshot.unreadCount
            }
            try save()
        } catch {
            logger.error("Local action revert failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Private fetch helpers

    private func save() throws {
        guard modelContext.hasChanges else { return }
        try modelContext.save()
    }

    private func fetchMessage(id: String) throws -> CachedMessage? {
        var descriptor = FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchThreadMessages(accountID: String, threadID: String) throws -> [CachedMessage] {
        try modelContext.fetch(
            FetchDescriptor<CachedMessage>(
                predicate: #Predicate { $0.accountID == accountID && $0.threadID == threadID }
            )
        )
    }

    private func fetchConversationRows(accountID: String, threadID: String) throws -> [CachedConversation] {
        try modelContext.fetch(
            FetchDescriptor<CachedConversation>(
                predicate: #Predicate { $0.accountID == accountID && $0.threadID == threadID }
            )
        )
    }

    /// Fetches only the ids we are about to upsert — never "load all, filter later".
    private func fetchMailboxes(accountID: String, ids: [String]) throws -> [String: CachedMailbox] {
        let wanted = Set(ids)
        let rows = try modelContext.fetch(
            FetchDescriptor<CachedMailbox>(
                predicate: #Predicate { $0.accountID == accountID && wanted.contains($0.id) }
            )
        )
        return Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func fetchMessages(accountID: String, ids: [String]) throws -> [String: CachedMessage] {
        guard !ids.isEmpty else { return [:] }
        let wanted = Set(ids)
        let rows = try modelContext.fetch(
            FetchDescriptor<CachedMessage>(
                predicate: #Predicate { $0.accountID == accountID && wanted.contains($0.id) }
            )
        )
        return Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func fetchConversations(
        accountID: String,
        listFolder: String,
        mailboxKey: String,
        threadIDs: [String]
    ) throws -> [String: CachedConversation] {
        let wanted = Set(threadIDs)
        let rows = try modelContext.fetch(
            FetchDescriptor<CachedConversation>(
                predicate: #Predicate {
                    $0.accountID == accountID
                        && $0.listFolder == listFolder
                        && $0.mailboxKey == mailboxKey
                        && wanted.contains($0.threadID)
                }
            )
        )
        return Dictionary(rows.map { ($0.threadID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Recomputes a thread's denormalized counters from its cached messages so
    /// an optimistic action shows up in the conversation list immediately.
    private func refreshConversationRows(
        _ rows: [CachedConversation],
        accountID: String,
        threadID: String
    ) throws {
        guard !rows.isEmpty else { return }
        let messages = try fetchThreadMessages(accountID: accountID, threadID: threadID)
        guard !messages.isEmpty else { return }
        let unread = messages.count { $0.readAt == nil }
        let starred = messages.contains { $0.starredAt != nil }
        let latest = messages.max { $0.sortDate < $1.sortDate }
        for row in rows {
            if row.unreadCount != unread { row.unreadCount = unread }
            if row.isStarred != starred { row.isStarred = starred }
            guard let latest else { continue }
            if row.readAt != latest.readAt { row.readAt = latest.readAt }
            if row.starredAt != latest.starredAt { row.starredAt = latest.starredAt }
            if row.folderRaw != latest.folderRaw { row.folderRaw = latest.folderRaw }
        }
    }

    private nonisolated static func messageScopePredicate(
        accountID: String,
        mailboxID: String?,
        folder: MailFolder
    ) -> Predicate<CachedMessage> {
        let folderRaw = folder.rawValue
        guard let mailboxID else {
            return #Predicate { $0.accountID == accountID && $0.folderRaw == folderRaw }
        }
        return #Predicate {
            $0.accountID == accountID && $0.folderRaw == folderRaw && $0.mailboxKey == mailboxID
        }
    }

    // MARK: - Mutation

    private nonisolated static func mutate(_ row: CachedMessage, with action: MessageAction) {
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
        }
    }

    private nonisolated static func snapshot(_ row: CachedMessage) -> MessageStateSnapshot {
        MessageStateSnapshot(
            messageID: row.id,
            readAt: row.readAt,
            starredAt: row.starredAt,
            folderRaw: row.folderRaw
        )
    }

    private nonisolated static func snapshot(_ row: CachedConversation) -> ConversationStateSnapshot {
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

    private nonisolated static func makeMailbox(_ dto: Mailbox, accountID: String) -> CachedMailbox {
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
    private nonisolated static func apply(_ dto: Mailbox, to row: CachedMailbox) -> Bool {
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

    private nonisolated static func apply(_ dto: MessageSummary, to row: CachedMessage) -> Bool {
        var changed = false
        if row.threadID != dto.threadID { row.threadID = dto.threadID; changed = true }
        let mailboxKey = dto.mailboxID ?? ""
        if row.mailboxKey != mailboxKey { row.mailboxKey = mailboxKey; changed = true }
        if row.directionRaw != dto.direction.rawValue { row.directionRaw = dto.direction.rawValue; changed = true }
        if row.folderRaw != dto.folder.rawValue { row.folderRaw = dto.folder.rawValue; changed = true }
        if row.fromAddress != dto.fromAddress { row.fromAddress = dto.fromAddress; changed = true }
        if row.toAddresses != dto.to { row.toAddresses = dto.to; changed = true }
        if row.subject != dto.subject { row.subject = dto.subject; changed = true }
        if row.snippet != dto.snippet { row.snippet = dto.snippet; changed = true }
        if row.receivedAt != dto.receivedAt { row.receivedAt = dto.receivedAt; changed = true }
        if row.sentAt != dto.sentAt { row.sentAt = dto.sentAt; changed = true }
        if row.readAt != dto.readAt { row.readAt = dto.readAt; changed = true }
        if row.starredAt != dto.starredAt { row.starredAt = dto.starredAt; changed = true }
        if row.hasAttachments != dto.hasAttachments { row.hasAttachments = dto.hasAttachments; changed = true }
        if row.createdAt != dto.createdAt { row.createdAt = dto.createdAt; changed = true }
        if row.sortDate != dto.displayDate { row.sortDate = dto.displayDate; changed = true }
        return changed
    }

    private nonisolated static func apply(_ dto: ConversationSummary, to row: CachedConversation) -> Bool {
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

    private nonisolated static func mailbox(from row: CachedMailbox) -> Mailbox {
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

    private nonisolated static func message(from row: CachedMessage) -> MessageSummary {
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

    private nonisolated static func conversation(from row: CachedConversation) -> ConversationSummary {
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
