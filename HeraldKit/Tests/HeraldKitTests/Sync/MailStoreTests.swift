import Foundation
import Testing
@testable import HeraldKit

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
        #expect(try await store.message(id: "m1")?.readAt == readAt)
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
        #expect(try await store.message(id: "m1") != nil)
        #expect(try await store.message(id: "m3") != nil, "Sibling mailbox must survive")
        #expect(try await store.message(id: "m4") != nil, "Sibling folder must survive")
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
        #expect(try await store.message(id: "m1")?.readAt != nil, "Action must land before the network call")
        try await store.revertLocalAction(undoA)
        #expect(try await store.message(id: "m1")?.readAt == nil, "Revert must restore unread")

        // B: a failed star on an already-read message must not clear readAt.
        let undoB = try await store.applyLocalAction(.star, messageID: "m2", accountID: account)
        #expect(try await store.message(id: "m2")?.starredAt != nil)
        try await store.revertLocalAction(undoB)
        let m2 = try await store.message(id: "m2")
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
        try Data("this is not a SQLite database".utf8).write(to: url)

        let container = try MailStoreContainer.make(url: url)
        let store = MailStore(modelContainer: container)
        _ = try await store.upsertMessages([SyncFixtures.message("m1")], accountID: account)
        #expect(try await store.message(id: "m1") != nil, "Rebuilt container must be usable")
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
        #expect(try await store.cachedBody(messageID: "m1")?.textBody == "hello")

        let again = try await store.storeBody(messageID: "m1", accountID: account, textBody: "hello", html: nil)
        #expect(again.isEmpty)
    }
}
