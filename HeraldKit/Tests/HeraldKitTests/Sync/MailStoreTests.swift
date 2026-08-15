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
}
