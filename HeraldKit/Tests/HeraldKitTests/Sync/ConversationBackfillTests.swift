import Foundation
import Testing
@testable import HeraldKit

/// Paging past the sync pass's conversation page cap
/// (``SyncEngine/loadOlderConversations(mailboxIDs:folder:)``).
@Suite("Conversation backfill past the page cap")
struct ConversationBackfillTests {
    private let account = SyncFixtures.account
    private static let inboxOnly = SyncScope(folders: [SyncFolder(message: .inbox, conversation: .inbox)])

    private func awaitPass(_ engine: SyncEngine) async {
        for await event in engine.events {
            if case .finished = event { return }
            if case .failed = event { return }
        }
    }

    /// Four one-row pages; the engine is capped at two, so a pass caches t1+t2
    /// and leaves `c2` as the first page it never fetched.
    private func makeEngine() async throws -> (FakeMailAPIClient, MailStore, SyncEngine) {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setConversationPages([
            ConversationPage(conversations: [SyncFixtures.conversation(threadID: "t1")], nextCursor: "c1", totalCount: nil),
            ConversationPage(conversations: [SyncFixtures.conversation(threadID: "t2")], nextCursor: "c2", totalCount: nil),
            ConversationPage(conversations: [SyncFixtures.conversation(threadID: "t3")], nextCursor: "c3", totalCount: nil),
            ConversationPage(conversations: [SyncFixtures.conversation(threadID: "t4")], nextCursor: nil, totalCount: nil),
        ])
        let store = try MailStore.inMemory()
        let engine = SyncEngine(api: api, store: store, scope: Self.inboxOnly, maxConversationPages: 2)
        await engine.start(accountID: account)
        await awaitPass(engine)
        return (api, store, engine)
    }

    private func cachedIDs(_ store: MailStore) async throws -> Set<String> {
        Set(try await store.conversations(accountID: account, mailboxIDs: ["mbx_a"], folder: .inbox, limit: 1000).map(\.id))
    }

    /// Fails if backfill does not resume at the capped cursor, if a later pass
    /// rewinds it (re-fetching page 3 forever) or tombstones the backfilled
    /// rows, or if the end of the listing is not reported.
    @Test("Backfill resumes at the cap, survives a re-walk, and stops at the last page")
    func backfillPagesToTheEnd() async throws {
        let (api, store, engine) = try await makeEngine()
        #expect(try await cachedIDs(store) == ["t1", "t2"])

        let more = try await engine.loadOlderConversations(mailboxIDs: ["mbx_a"], folder: .inbox)
        #expect(more, "c3 is still ahead")
        #expect(try await cachedIDs(store) == ["t1", "t2", "t3"])

        // A background pass re-walks (and caps) again: it must neither delete
        // t3 nor move the resume point back to c2.
        await engine.refreshNow()
        await awaitPass(engine)
        #expect(try await cachedIDs(store) == ["t1", "t2", "t3"], "a capped re-walk must not truncate backfilled rows")

        let more2 = try await engine.loadOlderConversations(mailboxIDs: ["mbx_a"], folder: .inbox)
        #expect(!more2, "page 4 has no nextCursor")
        #expect(try await cachedIDs(store) == ["t1", "t2", "t3", "t4"])

        let callsBefore = await api.conversationCursors().count
        let more3 = try await engine.loadOlderConversations(mailboxIDs: ["mbx_a"], folder: .inbox)
        #expect(!more3)
        #expect(await api.conversationCursors().count == callsBefore, "nothing left to fetch means no request")
        await engine.stop()

        #expect(await api.conversationCursors() == [nil, "c1", "c2", nil, "c1", "c3"])
        // Each thread exactly once: the page boundaries never duplicate a row.
        let rows = try await store.conversations(accountID: account, mailboxIDs: ["mbx_a"], folder: .inbox, limit: 1000)
        #expect(rows.count == 4)
    }

    /// Fails if a failed page drops the cursor (paging would silently end) or
    /// advances it (a page would be skipped).
    @Test("A failed backfill keeps its cursor for the retry")
    func failedBackfillRetries() async throws {
        let (api, store, engine) = try await makeEngine()
        await api.setListFailure(.server(code: "INTERNAL", message: "boom"))
        await #expect(throws: MailAPIError.self) {
            try await engine.loadOlderConversations(mailboxIDs: ["mbx_a"], folder: .inbox)
        }
        await api.setListFailure(nil)
        #expect(try await engine.loadOlderConversations(mailboxIDs: ["mbx_a"], folder: .inbox))
        #expect(try await cachedIDs(store) == ["t1", "t2", "t3"])
        await engine.stop()
        #expect(Array(await api.conversationCursors().suffix(2)) == ["c2", "c2"], "the retry asks for the same page")
    }

    /// Fails if backfill ignores the scope it was asked about (fetching every
    /// capped mailbox for a one-mailbox list) or the folder.
    @Test("Backfill only touches capped listings inside the asked scope")
    func backfillIsScoped() async throws {
        let (api, _, engine) = try await makeEngine()
        let before = await api.conversationCursors().count
        #expect(try await engine.loadOlderConversations(mailboxIDs: ["mbx_other"], folder: .inbox) == false)
        #expect(try await engine.loadOlderConversations(mailboxIDs: ["mbx_a"], folder: .archived) == false)
        #expect(await api.conversationCursors().count == before)
        // `nil` = every mailbox, which includes mbx_a.
        #expect(try await engine.loadOlderConversations(mailboxIDs: nil, folder: .inbox))
        await engine.stop()
    }

    /// Fails if a listing that fits under the cap leaves anything to backfill —
    /// the common case must cost no requests at all.
    @Test("An uncapped listing has nothing to backfill")
    func uncappedHasNothing() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setConversationPages([
            ConversationPage(conversations: [SyncFixtures.conversation(threadID: "t1")], nextCursor: nil, totalCount: nil),
        ])
        let engine = SyncEngine(api: api, store: try MailStore.inMemory(), scope: Self.inboxOnly)
        await engine.start(accountID: account)
        await awaitPass(engine)
        let before = await api.conversationCursors().count
        #expect(try await engine.loadOlderConversations(mailboxIDs: nil, folder: .inbox) == false)
        #expect(await api.conversationCursors().count == before)
        await engine.stop()
    }
}
