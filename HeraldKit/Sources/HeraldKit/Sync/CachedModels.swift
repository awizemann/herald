import Foundation
import SwiftData

// The SwiftData store is a REBUILDABLE CACHE, not the system of record — the
// HQBase server is. That is why there is no `VersionedSchema` and no
// `SchemaMigrationPlan` anywhere in this file: on an incompatible or corrupt
// store we delete and re-sync (see `MailStoreContainer`).
//
// Every model is `nonisolated`: the package builds with
// `.defaultIsolation(MainActor.self)`, and a `@MainActor` class cannot be
// touched from the `MailStore` @ModelActor.
//
// Filterable/sortable columns are stored as raw `String`s (`folderRaw`,
// `mailboxKey`) because `#Predicate` and `#Index` want concrete, non-optional
// stored properties; the typed DTO shapes are rebuilt in the mapping helpers.

/// A mailbox the account can see. Scoped by `accountID` like every cached row.
@Model
public nonisolated final class CachedMailbox {
    #Unique<CachedMailbox>([\.accountID, \.id])
    #Index<CachedMailbox>([\.accountID, \.id])

    /// Server mailbox id.
    public var id: String = ""
    public var accountID: String = ""
    public var address: String = ""
    public var addresses: [MailboxAddress] = []
    public var displayName: String = ""
    public var isActive: Bool = false
    /// Raw ``MailboxAccessLevel``; `nil` when the server reported none.
    public var accessLevelRaw: String?
    public var createdAt: Date = Date.distantPast
    public var updatedAt: Date = Date.distantPast

    public init(
        id: String,
        accountID: String,
        address: String,
        addresses: [MailboxAddress],
        displayName: String,
        isActive: Bool,
        accessLevelRaw: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.accountID = accountID
        self.address = address
        self.addresses = addresses
        self.displayName = displayName
        self.isActive = isActive
        self.accessLevelRaw = accessLevelRaw
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A thread as it appears in one listing scope.
///
/// Keyed by (`accountID`, `threadID`, `listFolder`, `mailboxKey`) rather than by
/// thread alone: the same thread legitimately appears under `inbox` and
/// `archived`, and `deleteMissing` has to be able to drop it from one scope
/// without touching the other.
@Model
public nonisolated final class CachedConversation {
    #Unique<CachedConversation>([\.accountID, \.threadID, \.listFolder, \.mailboxKey])
    // Column order matters: the hot query is (accountID, listFolder) with the
    // mailbox left open ("All Mailboxes"), so `listFolder` must precede
    // `mailboxKey` for that query to be served by an index prefix. `sortDate`
    // trails so the newest-first ordering comes out of the index too.
    #Index<CachedConversation>(
        [\.accountID, \.listFolder, \.mailboxKey, \.sortDate],
        [\.accountID, \.threadID]
    )

    public var threadID: String = ""
    public var accountID: String = ""
    /// Raw ``ConversationFolder`` this row was listed under.
    public var listFolder: String = ""
    /// `mailboxID ?? ""` — the indexable, predicate-friendly form.
    public var mailboxKey: String = ""

    // Denormalized latest-message summary (the row the list renders).
    public var latestMessageID: String = ""
    public var latestThreadID: String = ""
    public var latestMailboxKey: String = ""
    public var directionRaw: String = ""
    public var folderRaw: String = ""
    public var fromAddress: String = ""
    public var toAddresses: [String] = []
    public var subject: String = ""
    public var snippet: String = ""
    public var receivedAt: Date?
    public var sentAt: Date?
    public var readAt: Date?
    public var starredAt: Date?
    public var hasAttachments: Bool = false
    public var createdAt: Date = Date.distantPast

    // Thread-level counters.
    public var isStarred: Bool = false
    public var messageCount: Int = 0
    public var unreadCount: Int = 0
    /// Sort key, precomputed so list queries never sort in memory.
    public var sortDate: Date = Date.distantPast

    public init(
        threadID: String,
        accountID: String,
        listFolder: String,
        mailboxKey: String
    ) {
        self.threadID = threadID
        self.accountID = accountID
        self.listFolder = listFolder
        self.mailboxKey = mailboxKey
    }
}

/// A message summary row. Deliberately LEAN — no bodies here; the list query
/// touches this table constantly and a fat row makes every fetch pay for text
/// nobody is reading. Bodies live in ``CachedMessageBody``.
@Model
public nonisolated final class CachedMessage {
    #Unique<CachedMessage>([\.accountID, \.id])
    // Same prefix rule as `CachedConversation`: folder first, mailbox second, so
    // a mailbox-nil folder query is prefix-served.
    #Index<CachedMessage>(
        [\.accountID, \.folderRaw, \.mailboxKey, \.sortDate],
        [\.accountID, \.threadID]
    )

    public var id: String = ""
    public var accountID: String = ""
    public var threadID: String = ""
    /// `mailboxID ?? ""`.
    public var mailboxKey: String = ""
    public var directionRaw: String = ""
    /// Raw ``MailFolder``.
    public var folderRaw: String = ""
    public var fromAddress: String = ""
    public var toAddresses: [String] = []
    public var subject: String = ""
    public var snippet: String = ""
    public var receivedAt: Date?
    public var sentAt: Date?
    public var readAt: Date?
    public var starredAt: Date?
    public var hasAttachments: Bool = false
    public var createdAt: Date = Date.distantPast
    /// Sort key, precomputed (`receivedAt ?? sentAt ?? createdAt`).
    public var sortDate: Date = Date.distantPast

    public init(id: String, accountID: String) {
        self.id = id
        self.accountID = accountID
    }
}

/// On-demand body sidecar, keyed by message id. Kept out of ``CachedMessage``
/// so the hot list row stays small; dropping this table entirely would only
/// cost a refetch.
@Model
public nonisolated final class CachedMessageBody {
    #Unique<CachedMessageBody>([\.accountID, \.messageID])
    #Index<CachedMessageBody>([\.accountID, \.messageID])

    public var messageID: String = ""
    public var accountID: String = ""
    public var textBody: String = ""
    public var html: String?
    /// The message's attachment metadata, cached with the body so the attachment
    /// bar still renders when `GET /messages/{id}` is unavailable. Metadata only —
    /// the bytes are never cached here.
    public var attachments: [Attachment] = []
    public var fetchedAt: Date = Date.distantPast

    public init(
        messageID: String,
        accountID: String,
        textBody: String,
        html: String?,
        attachments: [Attachment] = [],
        fetchedAt: Date
    ) {
        self.messageID = messageID
        self.accountID = accountID
        self.textBody = textBody
        self.html = html
        self.attachments = attachments
        self.fetchedAt = fetchedAt
    }
}

/// One unsent draft, cached whole.
///
/// Drafts are NOT messages on the server: they live in their own tables, they
/// never appear in `GET /messages?folder=drafts` (which is dead), and they are
/// not written to the `/changes` journal. The only way to see them is
/// `GET /drafts`, which returns the WHOLE list with no pagination and no
/// `updatedSince` — so this table is reconciled by full-list diff.
///
/// The row carries every editable field rather than a summary, because opening
/// the composer from the Drafts folder must not cost a round trip: the whole
/// ``Draft`` (including its `version` stamp, which is the optimistic-concurrency
/// token `PATCH /drafts/{id}` needs) is rebuilt from here.
@Model
public nonisolated final class CachedDraft {
    #Unique<CachedDraft>([\.accountID, \.id])
    // The list query is (accountID) newest-first, so `updatedAt` trails the
    // account for an index-served sort; the second index serves single-row lookup.
    #Index<CachedDraft>(
        [\.accountID, \.updatedAt],
        [\.accountID, \.id]
    )

    /// Server draft id.
    public var id: String = ""
    public var accountID: String = ""
    /// Optimistic-concurrency stamp; the value a `PATCH` must echo back.
    public var version: Int = 0
    public var updatedAt: Date = Date.distantPast

    /// `mailboxID ?? ""` — same predicate-friendly form as everywhere else.
    public var mailboxKey: String = ""
    public var replyToMessageID: String?
    public var forwardOfMessageID: String?
    public var fromAddress: String = ""
    public var toAddresses: [String] = []
    public var ccAddresses: [String] = []
    public var bccAddresses: [String] = []
    public var subject: String = ""
    public var textBody: String = ""
    public var htmlBody: String = ""
    public var attachments: [DraftAttachment] = []
    /// The signature the server resolved for this draft. Cached because opening a
    /// draft from the Drafts folder builds its composer from THIS row: without it
    /// the composer would reopen as "no signature" and the next autosave would
    /// send `{"mode":"none"}`, quietly dropping the signature the draft had.
    public var signature: SignatureSnapshot = SignatureSnapshot.empty

    public init(id: String, accountID: String) {
        self.id = id
        self.accountID = accountID
    }
}

/// One workspace label, cached so the sidebar and the row chips draw offline.
@Model
public nonisolated final class CachedLabel {
    #Unique<CachedLabel>([\.accountID, \.id])
    // The list is always read whole for an account, sorted by name.
    #Index<CachedLabel>([\.accountID, \.sortName])

    public var id: String = ""
    public var accountID: String = ""
    public var name: String = ""
    /// Raw ``LabelColor``; an unknown value maps to the fallback on read.
    public var colorRaw: String = ""
    /// Lowercased `name`, so the sidebar's case-insensitive order (the server's
    /// own `COLLATE NOCASE`) comes out of the index instead of a Swift sort.
    public var sortName: String = ""
    public var createdAt: Date = Date.distantPast
    public var updatedAt: Date = Date.distantPast

    public init(id: String, accountID: String) {
        self.id = id
        self.accountID = accountID
    }
}

/// One (label, message) assignment.
///
/// A join row rather than a `[String]` column on ``CachedMessage``, because the
/// sweep that keeps this current is per-LABEL (`GET /messages?labelId=…` — the
/// only membership source v1 offers) and has to be able to replace one label's
/// whole set without rewriting every message row.
///
/// `threadID` is denormalized onto the row so a conversation's chips and the
/// sidebar's by-label listing are one indexed fetch rather than a join against
/// ``CachedMessage`` per row.
@Model
public nonisolated final class CachedLabelAssignment {
    #Unique<CachedLabelAssignment>([\.accountID, \.labelID, \.messageID])
    #Index<CachedLabelAssignment>(
        [\.accountID, \.labelID],
        [\.accountID, \.messageID],
        [\.accountID, \.threadID]
    )

    public var accountID: String = ""
    public var labelID: String = ""
    public var messageID: String = ""
    public var threadID: String = ""

    public init(accountID: String, labelID: String, messageID: String, threadID: String) {
        self.accountID = accountID
        self.labelID = labelID
        self.messageID = messageID
        self.threadID = threadID
    }
}

/// Where the account's sync got to: the change-journal cursor to resume from and
/// whether the full bootstrap listing ever completed.
///
/// Still part of the rebuildable cache — losing it costs one checkpoint plus one
/// full listing, never mail.
@Model
public nonisolated final class CachedSyncCheckpoint {
    #Unique<CachedSyncCheckpoint>([\.accountID])
    #Index<CachedSyncCheckpoint>([\.accountID])

    public var accountID: String = ""
    /// Opaque cursor from `GET /changes`; `nil` before the first checkpoint.
    public var changeCursor: String?
    /// When the full bootstrap listing finished. `nil` means "bootstrap again".
    public var bootstrappedAt: Date?

    public init(accountID: String, changeCursor: String?, bootstrappedAt: Date?) {
        self.accountID = accountID
        self.changeCursor = changeCursor
        self.bootstrappedAt = bootstrappedAt
    }
}

/// The checkpoint as a value type (no `@Model` escapes the store).
public nonisolated struct SyncCheckpoint: Sendable, Hashable {
    public let changeCursor: String?
    public let bootstrappedAt: Date?

    public init(changeCursor: String?, bootstrappedAt: Date?) {
        self.changeCursor = changeCursor
        self.bootstrappedAt = bootstrappedAt
    }

    /// A checkpoint the engine can resume from: both halves present.
    public var isBootstrapped: Bool { changeCursor != nil && bootstrappedAt != nil }
}

/// What deleting one cached message removed, plus the listing scope it lived in
/// — the engine needs the scope to know which conversation lists to re-derive.
public nonisolated struct MessageDeletion: Sendable, Hashable {
    public let changes: ChangeSet
    public let mailboxID: String?
    public let folder: MailFolder?

    public init(changes: ChangeSet, mailboxID: String?, folder: MailFolder?) {
        self.changes = changes
        self.mailboxID = mailboxID
        self.folder = folder
    }
}

/// A cached body handed back as a value type (no `@Model` escapes the store).
public nonisolated struct CachedBody: Sendable, Hashable {
    public let messageID: String
    public let textBody: String
    public let html: String?
    public let attachments: [Attachment]
    public let fetchedAt: Date

    public init(
        messageID: String,
        textBody: String,
        html: String?,
        attachments: [Attachment] = [],
        fetchedAt: Date
    ) {
        self.messageID = messageID
        self.textBody = textBody
        self.html = html
        self.attachments = attachments
        self.fetchedAt = fetchedAt
    }
}
