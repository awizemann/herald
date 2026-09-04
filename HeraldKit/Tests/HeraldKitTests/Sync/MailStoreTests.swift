import Foundation
import SwiftData
import Testing
@testable import HeraldKit

/// A model the real schema has never heard of, so a store written with it is a
/// VALID SQLite file that `MailStoreContainer.make(url:)` still cannot open.
@Model
nonisolated final class ForeignCachedRow {
    var marker: String = ""
    init(marker: String) { self.marker = marker }
}

@Suite("MailStore cache")
struct MailStoreTests {
    private let account = SyncFixtures.account

    /// Fails if `upsertMessages` blindly rewrites rows: a poll that returns the
    /// same data must produce an EMPTY ChangeSet, otherwise every 15s tick
    /// invalidates the whole list.
    @Test("Re-upserting identical data reports no changes")
    func idempotentUpsert() async throws {
        let store = try MailStore.inMemory()
        let messages = [SyncFixtures.message("m1"), SyncFixtures.message("m2", threadID: "thr_2")]

        let first = try await store.upsertMessages(messages, accountID: account)
        #expect(first.inserted == ["m1", "m2"])
        #expect(first.updated.isEmpty)

        let second = try await store.upsertMessages(messages, accountID: account)
        #expect(second.isEmpty, "Unchanged rows must not be reported as changed")
    }

    /// Fails if change detection is row-level rather than field-level: only the
    /// message whose readAt moved may appear in `updated`.
    @Test("A readAt change reports exactly that one message")
    func changeDetectionIsPerMessage() async throws {
        let store = try MailStore.inMemory()
        let before = [SyncFixtures.message("m1"), SyncFixtures.message("m2", threadID: "thr_2")]
        _ = try await store.upsertMessages(before, accountID: account)

        let readAt = Date(timeIntervalSince1970: 9_999)
        let after = [
            SyncFixtures.message("m1", readAt: readAt),
            SyncFixtures.message("m2", threadID: "thr_2"),
        ]
        let changes = try await store.upsertMessages(after, accountID: account)

        #expect(changes.updated == ["m1"])
        #expect(changes.inserted.isEmpty)
        #expect(changes.deleted.isEmpty)
        #expect(try await store.message(id: "m1", accountID: account)?.readAt == readAt)
    }

    /// Fails if `deleteMissing` ignores the mailbox/folder scope — the bug that
    /// would wipe archived mail every time the inbox is polled.
    @Test("Tombstoning is scoped to one mailbox and folder")
    func tombstoningRespectsScope() async throws {
        let store = try MailStore.inMemory()
        _ = try await store.upsertMessages(
            [
                SyncFixtures.message("m1", mailboxID: "mbx_a", folder: .inbox),
                SyncFixtures.message("m2", threadID: "thr_2", mailboxID: "mbx_a", folder: .inbox),
                SyncFixtures.message("m3", threadID: "thr_3", mailboxID: "mbx_b", folder: .inbox),
                SyncFixtures.message("m4", threadID: "thr_4", mailboxID: "mbx_a", folder: .archived),
            ],
            accountID: account
        )

        let changes = try await store.deleteMissingMessages(
            accountID: account,
            mailboxID: "mbx_a",
            folder: .inbox,
            keeping: ["m1"]
        )

        #expect(changes.deleted == ["m2"])
        #expect(try await store.message(id: "m1", accountID: account) != nil)
        #expect(try await store.message(id: "m3", accountID: account) != nil, "Sibling mailbox must survive")
        #expect(try await store.message(id: "m4", accountID: account) != nil, "Sibling folder must survive")
    }

    /// Fails if the revert restores a guessed state instead of the recorded one:
    /// case A must go back to unread, case B must KEEP its pre-existing readAt.
    @Test("Optimistic action applies immediately and reverts exactly")
    func optimisticActionRevertsExactly() async throws {
        let store = try MailStore.inMemory()
        let alreadyRead = Date(timeIntervalSince1970: 5_000)
        _ = try await store.upsertMessages(
            [
                SyncFixtures.message("m1"),
                SyncFixtures.message("m2", threadID: "thr_2", readAt: alreadyRead),
            ],
            accountID: account
        )

        // A: unread message marked read locally, then the server rejects it.
        let undoA = try await store.applyLocalAction(.read, messageID: "m1", accountID: account)
        #expect(try await store.message(id: "m1", accountID: account)?.readAt != nil, "Action must land before the network call")
        try await store.revertLocalAction(undoA)
        #expect(try await store.message(id: "m1", accountID: account)?.readAt == nil, "Revert must restore unread")

        // B: a failed star on an already-read message must not clear readAt.
        let undoB = try await store.applyLocalAction(.star, messageID: "m2", accountID: account)
        #expect(try await store.message(id: "m2", accountID: account)?.starredAt != nil)
        try await store.revertLocalAction(undoB)
        let m2 = try await store.message(id: "m2", accountID: account)
        #expect(m2?.starredAt == nil)
        #expect(m2?.readAt == alreadyRead, "Revert must not clobber unrelated state")
    }

    /// The optimistic write for `restore`/`unarchive` has to reproduce the
    /// server's `buildMessageActionPatch` exactly (worker/features/messages/
    /// actions.ts): unassigned → catchall, outbound → sent, otherwise inbox.
    /// Guessing "inbox" for all three would flash the row into the wrong list and
    /// then have sync yank it back out.
    @Test("Restore and unarchive land where the server puts them", arguments: [
        (MailFolder.trash, MessageAction.restore, "mbx_a", MessageDirection.inbound, MailFolder.inbox),
        (MailFolder.trash, MessageAction.restore, "mbx_a", MessageDirection.outbound, MailFolder.sent),
        (MailFolder.trash, MessageAction.restore, nil, MessageDirection.inbound, MailFolder.catchall),
        (MailFolder.archived, MessageAction.unarchive, "mbx_a", MessageDirection.inbound, MailFolder.inbox),
        (MailFolder.archived, MessageAction.unarchive, "mbx_a", MessageDirection.outbound, MailFolder.sent)
    ])
    func restoreLandsInTheServersFolder(
        from: MailFolder,
        action: MessageAction,
        mailboxID: String?,
        direction: MessageDirection,
        expected: MailFolder
    ) async throws {
        let store = try MailStore.inMemory()
        _ = try await store.upsertMessages(
            [SyncFixtures.message("m1", mailboxID: mailboxID, folder: from, direction: direction)],
            accountID: account
        )

        _ = try await store.applyLocalAction(action, messageID: "m1", accountID: account)

        #expect(try await store.message(id: "m1", accountID: account)?.folder == expected)
    }

    /// The server no-ops `restore` on anything that is not in the trash (and
    /// `unarchive` outside archived). A cache that moved the row anyway would
    /// show a message leaving the inbox that the server never touched.
    @Test("Restore on a message that is not trashed changes nothing")
    func restoreOutsideTrashIsANoOp() async throws {
        let store = try MailStore.inMemory()
        _ = try await store.upsertMessages(
            [SyncFixtures.message("m1", folder: .inbox)],
            accountID: account
        )

        _ = try await store.applyLocalAction(.restore, messageID: "m1", accountID: account)
        _ = try await store.applyLocalAction(.unarchive, messageID: "m1", accountID: account)

        #expect(try await store.message(id: "m1", accountID: account)?.folder == .inbox)
    }

    /// A revert restores a snapshot of the past. If the row has since moved on —
    /// the user kept triaging, or a tombstone took it — restoring that snapshot
    /// resurrects state the user already replaced. Fails on any revert that fires
    /// unconditionally: pre-fix the rejected archive dragged the message back out
    /// of the trash the user had just put it in.
    @Test("A rejected action does not roll back a row a later action already moved")
    func staleRevertLeavesANewerLocalChangeAlone() async throws {
        let store = try MailStore.inMemory()
        _ = try await store.upsertMessages([SyncFixtures.message("m1")], accountID: account)

        let archive = try await store.applyLocalAction(.archive, messageID: "m1", accountID: account)
        // The user keeps going before the first POST answers; trash owns the row now.
        _ = try await store.applyLocalAction(.trash, messageID: "m1", accountID: account)

        // Only now does the archive come back rejected.
        try await store.revertLocalAction(archive)

        #expect(
            try await store.message(id: "m1", accountID: account)?.folder == .trash,
            "a stale revert resurrected the pre-archive folder"
        )
        // …and the still-current action keeps its fence.
        #expect(await store.hasPendingMutation(messageID: "m1", accountID: account))
    }

    /// The mirror: a revert whose optimistic write is still the row's state is the
    /// ONLY case that may roll back, and it must also drop the fence — a leaked
    /// pending entry is a message the journal can never correct again.
    @Test("A rejected action rolls back its own untouched write and clears the fence")
    func revertOfAnUntouchedRowStillApplies() async throws {
        let store = try MailStore.inMemory()
        _ = try await store.upsertMessages([SyncFixtures.message("m1")], accountID: account)

        let undo = try await store.applyLocalAction(.star, messageID: "m1", accountID: account)
        #expect(await store.hasPendingMutation(messageID: "m1", accountID: account))
        try await store.revertLocalAction(undo)

        #expect(try await store.message(id: "m1", accountID: account)?.starredAt == nil)
        #expect(await store.hasPendingMutation(messageID: "m1", accountID: account) == false)
    }

    /// Fails if the container throws on an unreadable store file. The cache is
    /// rebuildable, so a corrupt file must cost a re-sync, not a broken launch.
    @Test("A corrupt store file is deleted and rebuilt")
    func corruptStoreIsRecovered() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HeraldSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("MailCache.store")
        let garbage = Data("this is not a SQLite database".utf8)
        try garbage.write(to: url)
        // Sidecars are replayed into whatever store file sits next to them, so the
        // recovery has to take them with it. Sentinel bytes, not inodes: the
        // rebuilt store immediately creates its own -wal/-shm and the filesystem
        // happily hands back the same inode number.
        let sidecars = ["-wal", "-shm"].map { URL(fileURLWithPath: url.path + $0) }
        let sentinel = Data("stale-sidecar-sentinel".utf8)
        for sidecar in sidecars { try sentinel.write(to: sidecar) }

        let container = try MailStoreContainer.make(url: url)
        let store = MailStore(modelContainer: container)
        _ = try await store.upsertMessages([SyncFixtures.message("m1")], accountID: account)
        #expect(try await store.message(id: "m1", accountID: account) != nil, "Rebuilt container must be usable")

        #expect(try Data(contentsOf: url) != garbage, "The unusable file was left in place")
        for sidecar in sidecars {
            #expect(
                (try? Data(contentsOf: sidecar)) != sentinel,
                "A stale \(sidecar.lastPathComponent) survived the rebuild"
            )
        }
    }

    /// The realistic version of the recovery path: not a garbage file but a
    /// perfectly VALID store written by a DIFFERENT schema — what a shipped
    /// version bump actually leaves behind. The contract the app depends on is
    /// "launch comes up on a usable cache", whichever way that is reached
    /// (SwiftData migrates this one in place rather than deleting it). Fails if a
    /// foreign-schema store makes `make(url:)` throw, or if the rebuilt cache
    /// still carries the foreign entity's rows.
    @Test("A store written by a different schema still yields a usable cache")
    func foreignSchemaStoreIsRecovered() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HeraldSchemaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("MailCache.store")

        // A valid store at our URL, holding a model our schema has never heard of.
        try autoreleasepool {
            let schema = Schema([ForeignCachedRow.self])
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
            let context = ModelContext(container)
            context.insert(ForeignCachedRow(marker: "not ours"))
            try context.save()
        }

        try #require(FileManager.default.fileExists(atPath: url.path), "The foreign store was never written")

        let container = try MailStoreContainer.make(url: url)
        let store = MailStore(modelContainer: container)
        _ = try await store.upsertMessages([SyncFixtures.message("m1")], accountID: account)
        #expect(try await store.message(id: "m1", accountID: account) != nil, "Recovered container must be usable")
        // The foreign entity must not be reachable through our schema at all.
        #expect(try await store.conversations(accountID: account, mailboxID: nil, folder: .inbox).isEmpty)
    }

    /// Fails if bodies are written into the hot message row or re-written on
    /// every read: the sidecar must round-trip and be change-detecting too.
    @Test("Bodies round-trip through the sidecar without rewriting")
    func bodySidecar() async throws {
        let store = try MailStore.inMemory()
        let first = try await store.storeBody(
            messageID: "m1",
            accountID: account,
            textBody: "hello",
            html: nil
        )
        #expect(first.inserted == ["m1"])
        #expect(try await store.cachedBody(messageID: "m1", accountID: account)?.textBody == "hello")

        let again = try await store.storeBody(messageID: "m1", accountID: account, textBody: "hello", html: nil)
        #expect(again.isEmpty)
    }

    /// Fails on any single-row lookup that keys on the message id alone. The
    /// `#Unique` is (accountID, messageID), so two signed-in servers may hold the
    /// same id: an unscoped fetch reads — and mutates — whichever row SQLite hands
    /// back first, i.e. the other account's mail.
    @Test("Single-message reads, body writes and local actions are scoped to one account")
    func perAccountRowsDoNotCollide() async throws {
        let store = try MailStore.inMemory()
        let accountA = "acct_a"
        let accountB = "acct_b"
        _ = try await store.upsertMessages([SyncFixtures.message("m1", subject: "A")], accountID: accountA)
        _ = try await store.upsertMessages([SyncFixtures.message("m1", subject: "B")], accountID: accountB)

        // Reads resolve to the asked-for account, not "the first m1".
        #expect(try await store.message(id: "m1", accountID: accountA)?.subject == "A")
        #expect(try await store.message(id: "m1", accountID: accountB)?.subject == "B")

        // Bodies live in a sidecar keyed the same way.
        _ = try await store.storeBody(messageID: "m1", accountID: accountA, textBody: "body-a", html: nil)
        _ = try await store.storeBody(messageID: "m1", accountID: accountB, textBody: "body-b", html: nil)
        #expect(try await store.cachedBody(messageID: "m1", accountID: accountA)?.textBody == "body-a")
        #expect(try await store.cachedBody(messageID: "m1", accountID: accountB)?.textBody == "body-b")

        // A local action on A must not mark B's message read.
        _ = try await store.applyLocalAction(.read, messageID: "m1", accountID: accountA)
        #expect(try await store.message(id: "m1", accountID: accountA)?.readAt != nil)
        #expect(try await store.message(id: "m1", accountID: accountB)?.readAt == nil, "The other account was mutated")
    }

    /// The body half of the local search index. Fails if it leaks another
    /// account's bodies, invents an entry for a message with no cached body
    /// (which would make search claim a hit the user can never see), or stops
    /// truncating — the index is held in memory for every row on screen, so an
    /// untruncated newsletter body is a real footprint regression.
    @Test("Cached body texts come back scoped, sparse and truncated")
    func cachedBodyTextsAreScopedAndTruncated() async throws {
        let store = try MailStore.inMemory()
        let other = "acct_other"
        let long = String(repeating: "x", count: 500)
        _ = try await store.storeBody(messageID: "m1", accountID: account, textBody: long, html: nil)
        _ = try await store.storeBody(messageID: "m3", accountID: other, textBody: "elsewhere", html: nil)

        let texts = try await store.cachedBodyTexts(
            messageIDs: ["m1", "m2", "m3"], accountID: account, maxLength: 100
        )

        #expect(texts["m1"]?.count == 100)
        // m2 has no cached body: search must simply not match it, never fetch one.
        #expect(texts["m2"] == nil)
        #expect(texts["m3"] == nil, "Another account's body reached this account's index")
    }

    /// The sidebar badge is a count, and it has to agree with the list it labels.
    /// Fails if `unreadCount` counts read threads, ignores the mailbox or account
    /// scope, or counts an unread thread a local archive has already moved out of
    /// the inbox (still listed under `inbox`, but hidden by the presentation rule).
    @Test("Unread counts match exactly the unread rows the scope presents")
    func unreadCountMatchesPresentedRows() async throws {
        let store = try MailStore.inMemory()
        let unread = SyncFixtures.conversation(threadID: "t1", latestID: "m1", unreadCount: 1)
        let read = SyncFixtures.conversation(threadID: "t2", latestID: "m2", unreadCount: 0)
        let locallyArchived = ConversationSummary(
            latest: SyncFixtures.message("m3", threadID: "t3", folder: .archived),
            isStarred: false,
            messageCount: 1,
            unreadCount: 1
        )
        // Two unread messages, but one thread: the badge counts threads.
        let otherMailbox = SyncFixtures.conversation(
            threadID: "t4", latestID: "m4", mailboxID: "mbx_b", unreadCount: 2
        )

        _ = try await store.upsertConversations(
            [unread, read, locallyArchived], accountID: account, mailboxID: "mbx_a", folder: .inbox
        )
        _ = try await store.upsertConversations(
            [locallyArchived], accountID: account, mailboxID: "mbx_a", folder: .archived
        )
        _ = try await store.upsertConversations(
            [otherMailbox], accountID: account, mailboxID: "mbx_b", folder: .inbox
        )

        #expect(try await store.unreadCount(accountID: account, mailboxID: "mbx_a") == 1)
        #expect(try await store.unreadCount(accountID: account, mailboxID: "mbx_b") == 1)
        #expect(try await store.unreadCount(accountID: account, mailboxID: nil) == 2)
        // The same row IS counted in the scope that does show it.
        #expect(try await store.unreadCount(accountID: account, mailboxID: "mbx_a", folder: .archived) == 1)
        #expect(try await store.unreadCount(accountID: "other_account", mailboxID: nil) == 0)
    }

    /// The Starred sidebar folder reads the same `conversations(folder:)` path as
    /// every other one, and starred rows are keyed by `listFolder == "starred"`.
    /// Fails if a starred upsert lands in the inbox scope instead (which is what
    /// happens if `starred` is treated as a message folder), or if the Starred
    /// badge stops counting.
    @Test("A conversation upserted into the starred folder shows up under the Starred scope")
    func starredConversationsListAndCountUnderTheirOwnScope() async throws {
        let store = try MailStore.inMemory()
        let starred = ConversationSummary(
            latest: SyncFixtures.message("m_star", threadID: "thr_star", starredAt: Date(timeIntervalSince1970: 3_000)),
            isStarred: true,
            messageCount: 1,
            unreadCount: 1
        )
        let plain = SyncFixtures.conversation(threadID: "thr_plain", latestID: "m_plain")

        _ = try await store.upsertConversations(
            [starred], accountID: account, mailboxID: "mbx_a", folder: .starred
        )
        _ = try await store.upsertConversations(
            [plain], accountID: account, mailboxID: "mbx_a", folder: .inbox
        )

        let starredScope = try await store.conversations(accountID: account, mailboxID: "mbx_a", folder: .starred)
        #expect(starredScope.map(\.id) == ["thr_star"])
        // …and it did NOT leak into the inbox scope.
        let inboxScope = try await store.conversations(accountID: account, mailboxID: "mbx_a", folder: .inbox)
        #expect(inboxScope.map(\.id) == ["thr_plain"])
        // The all-mailboxes Starred scope resolves too, and the badge counts it.
        #expect(try await store.conversations(accountID: account, mailboxID: nil, folder: .starred).count == 1)
        #expect(try await store.unreadCount(accountID: account, mailboxID: "mbx_a", folder: .starred) == 1)
    }
}
