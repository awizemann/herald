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
///
/// `token` identifies the action across the whole in-flight window: the store
/// keys its pending-mutation set by it, so a LATER action on the same message
/// takes ownership and an earlier action's completion cannot clear the newer
/// one's fence.
public nonisolated struct LocalActionUndo: Sendable, Hashable {
    public var accountID: String
    public var token: UUID
    public var messages: [MessageStateSnapshot]
    public var conversations: [ConversationStateSnapshot]
    /// Listing-scope rows the action CREATED: an archive/trash moves the thread
    /// into a scope the server has not listed yet, and the destination folder
    /// must show it now rather than after the next poll. They are the action's
    /// own invention, so a revert deletes them instead of restoring anything.
    public var insertedConversations: [ConversationStateSnapshot]

    public init(
        accountID: String,
        token: UUID = UUID(),
        messages: [MessageStateSnapshot] = [],
        conversations: [ConversationStateSnapshot] = [],
        insertedConversations: [ConversationStateSnapshot] = []
    ) {
        self.accountID = accountID
        self.token = token
        self.messages = messages
        self.conversations = conversations
        self.insertedConversations = insertedConversations
    }

    public var isEmpty: Bool { messages.isEmpty && conversations.isEmpty }
}

/// Pending mutations are keyed per ACCOUNT as well as per message: the `#Unique`
/// is (accountID, messageID) and two signed-in servers reuse ids, so a bare id
/// would fence the wrong account's row.
nonisolated struct PendingKey: Sendable, Hashable {
    let accountID: String
    let messageID: String
}

/// The optimistic state one in-flight local action wrote, held until the POST
/// settles. While an entry exists, `upsertMessages` refuses to overwrite these
/// three fields — a journal page cut mid-POST is by definition OLDER than the
/// mutation the user just made.
nonisolated struct PendingMutation: Sendable, Hashable {
    let token: UUID
    let readAt: Date?
    let starredAt: Date?
    let folderRaw: String
}

/// Where one cached message was listed, before an upsert moved it. A folder move
/// makes BOTH the old and the new conversation listing stale.
public nonisolated struct MessageScope: Sendable, Hashable {
    public let mailboxID: String?
    public let folder: MailFolder?

    public init(mailboxID: String?, folder: MailFolder?) {
        self.mailboxID = mailboxID
        self.folder = folder
    }
}

/// What a batch of message upserts changed, plus — for every row that already
/// existed — the scope it was in BEFORE the upsert.
public nonisolated struct MessageUpsertResult: Sendable, Hashable {
    public let changes: ChangeSet
    /// Keyed by message id; present only for rows that existed beforehand.
    public let previousScopes: [String: MessageScope]

    public init(changes: ChangeSet, previousScopes: [String: MessageScope]) {
        self.changes = changes
        self.previousScopes = previousScopes
    }
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
            logger.error("Mailbox fetch failed: \(error.localizedDescription, privacy: .private)")
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
            logger.error("Conversation fetch failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Whether one thread has a row in exactly this listing scope.
    ///
    /// The change feed reports bare ids: a thread id that resolves to no cached
    /// message is only worth a list reload if the row it names landed in the
    /// scope on screen. `fetchCount`, so nothing is materialised to answer it.
    public func hasConversation(
        threadID: String,
        accountID: String,
        mailboxID: String?,
        folder: ConversationFolder
    ) throws -> Bool {
        let listFolder = folder.rawValue
        let anyMailbox = mailboxID == nil
        let mailboxKey = mailboxID ?? ""
        let descriptor = FetchDescriptor<CachedConversation>(
            predicate: #Predicate {
                $0.accountID == accountID
                    && $0.threadID == threadID
                    && $0.listFolder == listFolder
                    && (anyMailbox || $0.mailboxKey == mailboxKey)
            }
        )
        do {
            return try modelContext.fetchCount(descriptor) > 0
        } catch {
            logger.error("Conversation scope check failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// How many threads in a listing scope are unread, counted in the store.
    ///
    /// The sidebar badge used to fetch and map up to 100 whole rows per mailbox on
    /// every reload just to count them; `fetchCount` never materialises a row.
    ///
    /// The unread test is `unreadCount > 0`, not `readAt == nil`: `readAt` is an
    /// optional `Date` and optional comparison in `#Predicate` is unreliable here
    /// (the same reason `mailboxKey` exists), while `unreadCount` is the
    /// non-optional thread-level mirror the list already renders from.
    /// The folder test mirrors the presentation rule — a row a local archive moved
    /// out of the inbox must stop being counted there immediately.
    public func unreadCount(
        accountID: String,
        mailboxID: String?,
        folder: ConversationFolder = .inbox
    ) throws -> Int {
        let listFolder = folder.rawValue
        let archived = MailFolder.archived.rawValue
        let trash = MailFolder.trash.rawValue
        let anyMailbox = mailboxID == nil
        let mailboxKey = mailboxID ?? ""
        let wantsExactFolder = folder == .archived || folder == .trash
        let exactFolder = folder == .archived ? archived : trash
        let descriptor = FetchDescriptor<CachedConversation>(
            predicate: #Predicate {
                $0.accountID == accountID
                    && $0.listFolder == listFolder
                    && $0.unreadCount > 0
                    && (anyMailbox || $0.mailboxKey == mailboxKey)
                    && ((wantsExactFolder && $0.folderRaw == exactFolder)
                        || (!wantsExactFolder && $0.folderRaw != archived && $0.folderRaw != trash))
            }
        )
        do {
            return try modelContext.fetchCount(descriptor)
        } catch {
            logger.error("Unread count failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Every cached message in a thread, NEWEST first — the same order as the
    /// conversation list (owner decision 2026-08-16: new mail is always on top),
    /// so the drilled-in thread view reads like the list it came from.
    public func messages(accountID: String, threadID: String) throws -> [MessageSummary] {
        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { $0.accountID == accountID && $0.threadID == threadID },
            sortBy: [SortDescriptor(\.sortDate, order: .reverse)]
        )
        do {
            return try modelContext.fetch(descriptor).map(Self.message(from:))
        } catch {
            logger.error("Thread fetch failed: \(error.localizedDescription, privacy: .private)")
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
            logger.error("Folder fetch failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// The `#Unique` key is (accountID, messageID): two accounts may legitimately
    /// hold the same server id, so every single-row lookup is account-scoped.
    public func message(id: String, accountID: String) throws -> MessageSummary? {
        do {
            return try fetchMessage(id: id, accountID: accountID).map(Self.message(from:))
        } catch {
            logger.error("Message fetch failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    // MARK: - Bodies (sidecar)

    public func cachedBody(messageID: String, accountID: String) throws -> CachedBody? {
        var descriptor = FetchDescriptor<CachedMessageBody>(
            predicate: #Predicate { $0.accountID == accountID && $0.messageID == messageID }
        )
        descriptor.fetchLimit = 1
        do {
            guard let row = try modelContext.fetch(descriptor).first else { return nil }
            return CachedBody(
                messageID: row.messageID,
                textBody: row.textBody,
                html: row.html,
                attachments: row.attachments,
                fetchedAt: row.fetchedAt
            )
        } catch {
            logger.error("Body fetch failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Cached body text for a set of messages, for the local search index.
    ///
    /// Only the rows that HAVE a cached body come back — search never fetches a
    /// body it does not already hold (a full mailbox of bodies is a download the
    /// user did not ask for, and the sidecar is populated as a side effect of
    /// reading). Each body is truncated to `maxLength` characters: the index is
    /// held in memory by the view-model for every row on screen, and a handful of
    /// newsletter-sized bodies would otherwise dominate the app's footprint.
    public func cachedBodyTexts(
        messageIDs: [String],
        accountID: String,
        maxLength: Int = 4096
    ) throws -> [String: String] {
        guard !messageIDs.isEmpty else { return [:] }
        let wanted = Set(messageIDs)
        do {
            let rows = try modelContext.fetch(
                FetchDescriptor<CachedMessageBody>(
                    predicate: #Predicate { $0.accountID == accountID && wanted.contains($0.messageID) }
                )
            )
            var texts: [String: String] = [:]
            texts.reserveCapacity(rows.count)
            for row in rows where !row.textBody.isEmpty {
                texts[row.messageID] = String(row.textBody.prefix(maxLength))
            }
            return texts
        } catch {
            logger.error("Body index fetch failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    @discardableResult
    public func storeBody(
        messageID: String,
        accountID: String,
        textBody: String,
        html: String?,
        attachments: [Attachment] = [],
        fetchedAt: Date = Date()
    ) throws -> ChangeSet {
        var descriptor = FetchDescriptor<CachedMessageBody>(
            predicate: #Predicate { $0.accountID == accountID && $0.messageID == messageID }
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
                        attachments: attachments,
                        fetchedAt: fetchedAt
                    )
                )
                try save()
                return ChangeSet(inserted: [messageID])
            }
            var changed = false
            if existing.textBody != textBody { existing.textBody = textBody; changed = true }
            if existing.html != html { existing.html = html; changed = true }
            // An empty list is "this write knew nothing about attachments" (the
            // plain-text path), never "the message lost its attachments" — it must
            // not wipe metadata a previous detail fetch cached.
            if !attachments.isEmpty, existing.attachments != attachments {
                existing.attachments = attachments
                changed = true
            }
            guard changed else { return ChangeSet() }
            existing.fetchedAt = fetchedAt
            try save()
            return ChangeSet(updated: [messageID])
        } catch {
            logger.error("Body store failed: \(error.localizedDescription, privacy: .private)")
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
            logger.error("Mailbox upsert failed: \(error.localizedDescription, privacy: .private)")
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
            logger.error("Conversation upsert failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Upserts message summaries. A message's identity is its server id, so the
    /// scope arguments are not needed — a message that moved folder is an update.
    @discardableResult
    public func upsertMessages(_ messages: [MessageSummary], accountID: String) throws -> ChangeSet {
        try applyMessageUpserts(messages, accountID: accountID).changes
    }

    /// The same upsert, reporting each pre-existing row's previous listing scope.
    ///
    /// Two invariants live here:
    /// - A row with a PENDING local mutation keeps its optimistic
    ///   `readAt`/`starredAt`/`folder`; everything else in the summary is
    ///   accepted. A journal page assembled before the user's POST landed would
    ///   otherwise un-star the row under their cursor.
    /// - The previous (mailbox, folder) is handed back so the caller can refresh
    ///   the listing the message MOVED OUT of, not just the one it landed in.
    @discardableResult
    public func applyMessageUpserts(
        _ messages: [MessageSummary],
        accountID: String
    ) throws -> MessageUpsertResult {
        guard !messages.isEmpty else { return MessageUpsertResult(changes: ChangeSet(), previousScopes: [:]) }
        var changes = ChangeSet()
        var previousScopes: [String: MessageScope] = [:]
        do {
            let existing = try fetchMessages(accountID: accountID, ids: messages.map(\.id))
            for dto in messages {
                guard let row = existing[dto.id] else {
                    let row = CachedMessage(id: dto.id, accountID: accountID)
                    _ = Self.apply(dto, to: row, pending: nil)
                    modelContext.insert(row)
                    changes.inserted.insert(dto.id)
                    continue
                }
                previousScopes[dto.id] = MessageScope(
                    mailboxID: row.mailboxKey.isEmpty ? nil : row.mailboxKey,
                    folder: MailFolder(rawValue: row.folderRaw)
                )
                if Self.apply(dto, to: row, pending: pendingMutations[PendingKey(accountID: accountID, messageID: dto.id)]) {
                    changes.updated.insert(dto.id)
                }
            }
            if !changes.isEmpty { try save() }
            return MessageUpsertResult(changes: changes, previousScopes: previousScopes)
        } catch {
            logger.error("Message upsert failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    // MARK: - Sync checkpoint

    /// Where the account's change-journal sync got to, or `nil` if it never started.
    public func syncCheckpoint(accountID: String) throws -> SyncCheckpoint? {
        do {
            guard let row = try fetchCheckpoint(accountID: accountID) else { return nil }
            return SyncCheckpoint(changeCursor: row.changeCursor, bootstrappedAt: row.bootstrappedAt)
        } catch {
            logger.error("Checkpoint fetch failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    public func setSyncCheckpoint(_ checkpoint: SyncCheckpoint, accountID: String) throws {
        do {
            guard let row = try fetchCheckpoint(accountID: accountID) else {
                modelContext.insert(
                    CachedSyncCheckpoint(
                        accountID: accountID,
                        changeCursor: checkpoint.changeCursor,
                        bootstrappedAt: checkpoint.bootstrappedAt
                    )
                )
                try save()
                return
            }
            if row.changeCursor != checkpoint.changeCursor { row.changeCursor = checkpoint.changeCursor }
            if row.bootstrappedAt != checkpoint.bootstrappedAt { row.bootstrappedAt = checkpoint.bootstrappedAt }
            try save()
        } catch {
            logger.error("Checkpoint store failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Forgets the checkpoint so the next pass re-bootstraps (410 `CHANGE_CURSOR_EXPIRED`).
    public func clearSyncCheckpoint(accountID: String) throws {
        do {
            try modelContext.delete(model: CachedSyncCheckpoint.self, where: #Predicate { $0.accountID == accountID })
            try save()
        } catch {
            logger.error("Checkpoint clear failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    private func fetchCheckpoint(accountID: String) throws -> CachedSyncCheckpoint? {
        var descriptor = FetchDescriptor<CachedSyncCheckpoint>(
            predicate: #Predicate { $0.accountID == accountID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Drops every cached row for an account (sign-out, or a forced rebuild).
    public func deleteAll(accountID: String) throws {
        do {
            // Nothing is left to fence, and a surviving entry would silently
            // block the NEXT account's journal from writing the same id.
            pendingMutations = pendingMutations.filter { $0.key.accountID != accountID }
            // Same reasoning for the draft fence: a surviving entry would stop the
            // NEXT account's poll from ever tombstoning that id.
            openDrafts = openDrafts.filter { $0.accountID != accountID }
            try modelContext.delete(model: CachedSyncCheckpoint.self, where: #Predicate { $0.accountID == accountID })
            try modelContext.delete(model: CachedDraft.self, where: #Predicate { $0.accountID == accountID })
            try modelContext.delete(model: CachedMessageBody.self, where: #Predicate { $0.accountID == accountID })
            try modelContext.delete(model: CachedMessage.self, where: #Predicate { $0.accountID == accountID })
            try modelContext.delete(model: CachedConversation.self, where: #Predicate { $0.accountID == accountID })
            try modelContext.delete(model: CachedMailbox.self, where: #Predicate { $0.accountID == accountID })
            try modelContext.delete(model: CachedLabelAssignment.self, where: #Predicate { $0.accountID == accountID })
            try modelContext.delete(model: CachedLabel.self, where: #Predicate { $0.accountID == accountID })
            try save()
        } catch {
            logger.error("Cache purge failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    // MARK: - Optimistic local actions

    /// Messages whose optimistic state is not yet confirmed by the server,
    /// keyed by message id. See ``applyMessageUpserts(_:accountID:)``.
    var pendingMutations: [PendingKey: PendingMutation] = [:]

    /// Drafts with a composer open on them. Same idea as ``pendingMutations``,
    /// for the one table the poll reconciles by full-list diff: while an entry
    /// exists, `reconcileDrafts` may not delete the row and may not write a
    /// listing older than the composer's last save over it. See
    /// `MailStore+Drafts.swift`, which owns every use of it.
    var openDrafts: Set<DraftKey> = []

    /// Test seam: whether a message is currently fenced against journal upserts.
    /// A leak here is a message the journal can never correct again.
    func hasPendingMutation(messageID: String, accountID: String) -> Bool {
        pendingMutations[PendingKey(accountID: accountID, messageID: messageID)] != nil
    }

    /// Applies a message action locally, right now, and returns the undo token.
    /// An empty undo means the message is not cached (nothing to revert).
    public func applyLocalAction(
        _ action: MessageAction,
        messageID: String,
        accountID: String
    ) throws -> LocalActionUndo {
        do {
            guard let row = try fetchMessage(id: messageID, accountID: accountID) else {
                logger.warning("Local action \(action.rawValue, privacy: .public) on uncached message")
                return LocalActionUndo(accountID: accountID)
            }
            let threadID = row.threadID
            let conversationRows = try fetchConversationRows(accountID: accountID, threadID: threadID)
            var undo = LocalActionUndo(
                accountID: accountID,
                messages: [Self.snapshot(row)],
                conversations: conversationRows.map(Self.snapshot)
            )
            Self.mutate(row, with: action)
            markPending(row, token: undo.token)
            try refreshConversationRows(conversationRows, accountID: accountID, threadID: threadID)
            undo.insertedConversations = try materializeMovedScope(
                accountID: accountID, threadID: threadID, from: conversationRows
            )
            try save()
            return undo
        } catch {
            logger.error("Local message action failed: \(error.localizedDescription, privacy: .private)")
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
            var undo = LocalActionUndo(
                accountID: accountID,
                messages: messageRows.map(Self.snapshot),
                conversations: conversationRows.map(Self.snapshot)
            )
            let messageAction = MessageAction(rawValue: action.rawValue)
            for row in messageRows {
                if let messageAction { Self.mutate(row, with: messageAction) }
                markPending(row, token: undo.token)
            }
            try refreshConversationRows(conversationRows, accountID: accountID, threadID: threadID)
            undo.insertedConversations = try materializeMovedScope(
                accountID: accountID, threadID: threadID, from: conversationRows
            )
            try save()
            return undo
        } catch {
            logger.error("Local conversation action failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// The server ACCEPTED the action: its answer is authoritative, so the fence
    /// comes down first and the returned summaries are written over the
    /// optimistic guess (they carry the server's real timestamps).
    @discardableResult
    public func completeLocalAction(
        _ undo: LocalActionUndo,
        applying summaries: [MessageSummary] = []
    ) throws -> ChangeSet {
        clearPending(undo)
        guard !summaries.isEmpty else {
            try refreshConversations(for: undo)
            return ChangeSet()
        }
        let changes = try upsertMessages(summaries, accountID: undo.accountID)
        try refreshConversations(for: undo)
        return changes
    }

    /// The server REJECTED the action. The fence comes down either way, but the
    /// row is only rolled back if it still holds exactly what the action wrote:
    /// a journal page (or a later action) that has since moved it on is newer
    /// truth, and restoring a stale snapshot over it would resurrect the past.
    public func revertLocalAction(_ undo: LocalActionUndo) throws {
        let pending = pendingSnapshot(undo)
        clearPending(undo)
        guard !undo.isEmpty else { return }
        do {
            // The destination-scope rows this action invented never existed on
            // the server; nothing else can own them, so they go first.
            for snapshot in undo.insertedConversations {
                guard let row = try fetchConversationRow(snapshot, accountID: undo.accountID) else { continue }
                modelContext.delete(row)
            }
            let byID = try fetchMessages(accountID: undo.accountID, ids: undo.messages.map(\.messageID))
            var revertedThreads: Set<String> = []
            for snapshot in undo.messages {
                guard let row = byID[snapshot.messageID] else { continue }
                // Only this action's own optimistic write may be undone. A
                // missing entry means a LATER action (or a tombstone) took the
                // row over; a differing one means the row moved on while the
                // POST was in flight. Either way the snapshot is stale history
                // and restoring it would resurrect the past.
                guard let optimistic = pending[snapshot.messageID],
                      row.readAt == optimistic.readAt,
                      row.starredAt == optimistic.starredAt,
                      row.folderRaw == optimistic.folderRaw
                else {
                    logger.warning("Skipping revert: the row moved on since the action was sent")
                    continue
                }
                row.readAt = snapshot.readAt
                row.starredAt = snapshot.starredAt
                row.folderRaw = snapshot.folderRaw
                revertedThreads.insert(row.threadID)
            }
            // Conversation rows are derived, so re-derive them rather than
            // restoring a snapshot that may now disagree with the messages.
            for threadID in revertedThreads {
                let rows = try fetchConversationRows(accountID: undo.accountID, threadID: threadID)
                try refreshConversationRows(rows, accountID: undo.accountID, threadID: threadID)
            }
            // A thread with no cached messages left has nothing to derive from;
            // its snapshot is the only truth available.
            for snapshot in undo.conversations where !revertedThreads.contains(snapshot.threadID) {
                guard try fetchThreadMessages(accountID: undo.accountID, threadID: snapshot.threadID).isEmpty,
                      let row = try fetchConversationRow(snapshot, accountID: undo.accountID)
                else { continue }
                row.readAt = snapshot.readAt
                row.starredAt = snapshot.starredAt
                row.folderRaw = snapshot.folderRaw
                row.isStarred = snapshot.isStarred
                row.unreadCount = snapshot.unreadCount
            }
            try save()
        } catch {
            logger.error("Local action revert failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    private func markPending(_ row: CachedMessage, token: UUID) {
        pendingMutations[PendingKey(accountID: row.accountID, messageID: row.id)] = PendingMutation(
            token: token,
            readAt: row.readAt,
            starredAt: row.starredAt,
            folderRaw: row.folderRaw
        )
    }

    /// This action's own pending entries — a message the user acted on AGAIN
    /// belongs to the newer token and is not ours to read or clear.
    private func pendingSnapshot(_ undo: LocalActionUndo) -> [String: PendingMutation] {
        var result: [String: PendingMutation] = [:]
        for snapshot in undo.messages {
            let key = PendingKey(accountID: undo.accountID, messageID: snapshot.messageID)
            guard let entry = pendingMutations[key], entry.token == undo.token else { continue }
            result[snapshot.messageID] = entry
        }
        return result
    }

    private func clearPending(_ undo: LocalActionUndo) {
        for snapshot in undo.messages {
            let key = PendingKey(accountID: undo.accountID, messageID: snapshot.messageID)
            guard pendingMutations[key]?.token == undo.token else { continue }
            pendingMutations[key] = nil
        }
    }

    private func refreshConversations(for undo: LocalActionUndo) throws {
        var threads: Set<String> = Set(undo.conversations.map(\.threadID))
        let byID = try fetchMessages(accountID: undo.accountID, ids: undo.messages.map(\.messageID))
        for row in byID.values { threads.insert(row.threadID) }
        for threadID in threads {
            let rows = try fetchConversationRows(accountID: undo.accountID, threadID: threadID)
            try refreshConversationRows(rows, accountID: undo.accountID, threadID: threadID)
        }
        try save()
    }

    private func fetchConversationRow(
        _ snapshot: ConversationStateSnapshot,
        accountID: String
    ) throws -> CachedConversation? {
        let threadID = snapshot.threadID
        let listFolder = snapshot.listFolder
        let mailboxKey = snapshot.mailboxKey
        var descriptor = FetchDescriptor<CachedConversation>(
            predicate: #Predicate {
                $0.accountID == accountID
                    && $0.threadID == threadID
                    && $0.listFolder == listFolder
                    && $0.mailboxKey == mailboxKey
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    // MARK: - Private fetch helpers

    func save() throws {
        guard modelContext.hasChanges else { return }
        try modelContext.save()
    }

    func fetchMessage(id: String, accountID: String) throws -> CachedMessage? {
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { $0.accountID == accountID && $0.id == id }
        )
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

    /// Mirrors an optimistic folder move into the listing scope it moved INTO.
    ///
    /// `applyLocalAction` changes each message's folder and re-derives the rows
    /// the thread was already listed under — but a thread trashed out of the
    /// inbox has no `trash`-scope row at all until the server lists it, so the
    /// Trash folder showed nothing until a poll happened to create one (and a
    /// Refresh that produced no ChangeSet never did). The row is created here,
    /// from the same denormalized source the listing renders.
    ///
    /// Returns the scopes it created, so a revert can delete exactly those.
    private func materializeMovedScope(
        accountID: String,
        threadID: String,
        from sources: [CachedConversation]
    ) throws -> [ConversationStateSnapshot] {
        guard let source = sources.first else { return [] }
        let messages = try fetchThreadMessages(accountID: accountID, threadID: threadID)
        guard let latest = messages.max(by: { $0.sortDate < $1.sortDate }),
              let destination = ConversationFolder(rawValue: latest.folderRaw),
              !sources.contains(where: { $0.listFolder == destination.rawValue })
        else { return [] }
        let listFolder = destination.rawValue
        var created: [ConversationStateSnapshot] = []
        // One row per mailbox scope the thread was listed in — that is exactly
        // the set of listings the user can be looking at.
        for mailboxKey in Set(sources.map(\.mailboxKey)) {
            let row = CachedConversation(
                threadID: threadID,
                accountID: accountID,
                listFolder: listFolder,
                mailboxKey: mailboxKey
            )
            Self.copyPresentation(from: source, to: row)
            modelContext.insert(row)
            try refreshConversationRows([row], accountID: accountID, threadID: threadID)
            created.append(Self.snapshot(row))
        }
        return created
    }

    /// Everything the list renders that is not re-derived from the messages.
    private nonisolated static func copyPresentation(
        from source: CachedConversation,
        to row: CachedConversation
    ) {
        row.latestMessageID = source.latestMessageID
        row.latestThreadID = source.latestThreadID
        row.latestMailboxKey = source.latestMailboxKey
        row.directionRaw = source.directionRaw
        row.folderRaw = source.folderRaw
        row.fromAddress = source.fromAddress
        row.toAddresses = source.toAddresses
        row.subject = source.subject
        row.snippet = source.snippet
        row.receivedAt = source.receivedAt
        row.sentAt = source.sentAt
        row.readAt = source.readAt
        row.starredAt = source.starredAt
        row.hasAttachments = source.hasAttachments
        row.createdAt = source.createdAt
        row.isStarred = source.isStarred
        row.messageCount = source.messageCount
        row.unreadCount = source.unreadCount
        row.sortDate = source.sortDate
    }

    nonisolated static func messageScopePredicate(
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
}
