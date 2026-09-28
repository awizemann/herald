import Foundation
import Testing
@testable import HeraldKit

/// The triage fence (`pendingMutations`) protects a MESSAGE row's three owned
/// fields from a stale journal page. A sync pass writes two more things from
/// listings it fetched before the user's POST landed: the denormalized
/// CONVERSATION rows (`upsertConversations`) and the tombstone sweep of a
/// re-listed scope (`deleteMissingMessages` / `deleteMissingConversations`).
/// Each test holds the POST open on the fake's gate, applies exactly what the
/// engine applies from such a pre-POST listing, and checks the optimistic state
/// survives until the action settles.
@Suite("Optimistic action vs concurrent sync pass")
struct OptimisticFenceTests {
    private let account = SyncFixtures.account

    /// Seeds m1 in the inbox and its inbox conversation row, then starts `action`
    /// with the POST parked on the gate.
    private func startGatedAction(
        _ action: MessageAction,
        api: FakeMailAPIClient,
        store: MailStore
    ) async throws -> Task<Void, Error> {
        _ = try await store.upsertMessages([SyncFixtures.message("m1", threadID: "t1")], accountID: account)
        _ = try await store.upsertConversations(
            [SyncFixtures.conversation(threadID: "t1", latestID: "m1")],
            accountID: account, mailboxID: "mbx_a", folder: .inbox
        )
        await api.armGate()
        let service = MailActionService(api: api, store: store)
        let post = Task { [account] in try await service.perform(action, on: "m1", accountID: account) }
        try await waitUntil("the action to reach the server") {
            await api.callCount { $0 == .performMessage(action, "m1") } == 1
        }
        return post
    }

    private func inboxRow(_ store: MailStore) async throws -> ConversationSummary? {
        try await store.conversations(accountID: account, mailboxIDs: ["mbx_a"], folder: .inbox)
            .first { $0.id == "t1" }
    }

    /// Fails on current-main behaviour where `upsertConversations` copies the
    /// listing's `isStarred`/`latest` verbatim: the list row un-stars under
    /// the user's cursor mid-POST.
    @Test("A stale conversation listing mid-POST does not snap the list row back")
    func staleConversationListingKeepsOptimisticRow() async throws {
        let api = FakeMailAPIClient()
        let store = try MailStore.inMemory()
        let post = try await startGatedAction(.star, api: api, store: store)

        // The pre-POST listing: unstarred, but with a newer subject.
        let stale = ConversationSummary(
            latest: SyncFixtures.message("m1", threadID: "t1", subject: "Re: fresh"),
            isStarred: false, messageCount: 1, unreadCount: 1
        )
        _ = try await store.upsertConversations([stale], accountID: account, mailboxID: "mbx_a", folder: .inbox)

        let mid = try #require(try await inboxRow(store))
        #expect(mid.isStarred, "a pre-POST conversation listing un-starred the row mid-flight")
        #expect(mid.latest.starredAt != nil)
        #expect(mid.latest.subject == "Re: fresh", "unfenced fields from the listing must still apply")

        await api.openGate()
        try await post.value
        #expect(try await inboxRow(store)?.isStarred == true)
    }

    /// Legacy re-list: the archived scope is listed from a response that predates
    /// the archive, so m1 is "missing" from it. Tombstoning it deleted the row the
    /// user just archived (and its fence) until the next poll.
    @Test("A stale destination listing mid-POST does not tombstone the moved message")
    func staleListingDoesNotTombstoneAPendingMove() async throws {
        let api = FakeMailAPIClient()
        let store = try MailStore.inMemory()
        let post = try await startGatedAction(.archive, api: api, store: store)
        #expect(try await store.message(id: "m1", accountID: account)?.folder == .archived)

        let deleted = try await store.deleteMissingMessages(
            accountID: account, mailboxID: "mbx_a", folder: .archived, keeping: []
        )
        let conversationsDeleted = try await store.deleteMissingConversations(
            accountID: account, mailboxID: "mbx_a", folder: .archived, keeping: []
        )
        #expect(deleted.deleted.isEmpty, "a pre-POST listing tombstoned the message being archived")
        #expect(conversationsDeleted.deleted.isEmpty, "a pre-POST listing tombstoned the materialised archive row")
        #expect(try await store.message(id: "m1", accountID: account)?.folder == .archived)
        #expect(await store.hasPendingMutation(messageID: "m1", accountID: account))

        await api.openGate()
        try await post.value
        #expect(await store.hasPendingMutation(messageID: "m1", accountID: account) == false)

        // Once settled the fence is down and tombstoning works again: the guard is
        // scoped to in-flight actions, not a permanent exemption.
        let after = try await store.deleteMissingMessages(
            accountID: account, mailboxID: "mbx_a", folder: .archived, keeping: []
        )
        #expect(after.deleted == ["m1"])
    }

    /// The fence must not swallow unrelated threads: a stale listing still
    /// updates and tombstones everything nobody is acting on.
    @Test("The fence is scoped to the acted-on thread")
    func fenceIsScopedToItsThread() async throws {
        let api = FakeMailAPIClient()
        let store = try MailStore.inMemory()
        _ = try await store.upsertMessages([SyncFixtures.message("m2", threadID: "t2")], accountID: account)
        _ = try await store.upsertConversations(
            [SyncFixtures.conversation(threadID: "t2", latestID: "m2")],
            accountID: account, mailboxID: "mbx_a", folder: .inbox
        )
        let post = try await startGatedAction(.star, api: api, store: store)

        let other = ConversationSummary(
            latest: SyncFixtures.message("m2", threadID: "t2", starredAt: Date(timeIntervalSince1970: 9)),
            isStarred: true, messageCount: 1, unreadCount: 1
        )
        _ = try await store.upsertConversations([other], accountID: account, mailboxID: "mbx_a", folder: .inbox)
        let t2 = try await store.conversations(accountID: account, mailboxIDs: ["mbx_a"], folder: .inbox)
            .first { $0.id == "t2" }
        #expect(t2?.isStarred == true, "an unrelated thread stopped tracking the server")

        let deleted = try await store.deleteMissingMessages(
            accountID: account, mailboxID: "mbx_a", folder: .inbox, keeping: []
        )
        #expect(deleted.deleted == ["m2"], "only the pending message may be spared")

        await api.openGate()
        try await post.value
    }
}
