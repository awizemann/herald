import Foundation
import HeraldKit
import Testing
@testable import Herald

/// One assembled view-model plus the handles the tests drive it with.
@MainActor
private struct Harness {
    let store: MailStore
    let api: FakeMailAPIClient
    let model: MailViewModel
    let events: AsyncStream<SyncEvent>.Continuation

    /// `markReadDelay` is injected rather than waited on: the dwell rule is
    /// tested from both sides without a real timer.
    static func make(markReadDelay: Duration = .seconds(3600)) async throws -> Harness {
        let store = try MailStore.inMemory()
        let api = FakeMailAPIClient()
        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .unbounded)
        let model = MailViewModel(
            accountID: "acct",
            accountLabel: "Test",
            api: api,
            store: store,
            actions: MailActionService(api: api, store: store),
            events: stream,
            markReadDelay: markReadDelay
        )
        return Harness(store: store, api: api, model: model, events: continuation)
    }

    /// Seeds mailbox A (thread `t1`, message `m1`) and mailbox B (`t2`/`m2`).
    func seedTwoMailboxes(subjectA: String = "Original") async throws {
        try await store.upsertMailboxes([Self.mailbox("mbA"), Self.mailbox("mbB")], accountID: "acct")
        let a = MailFixtures.message(id: "m1", threadID: "t1", mailboxID: "mbA", subject: subjectA)
        let b = MailFixtures.message(id: "m2", threadID: "t2", mailboxID: "mbB", subject: "Other")
        try await store.upsertMessages([a, b], accountID: "acct")
        try await store.upsertConversations(
            [MailFixtures.conversation(a)], accountID: "acct", mailboxID: "mbA", folder: .inbox
        )
        try await store.upsertConversations(
            [MailFixtures.conversation(b)], accountID: "acct", mailboxID: "mbB", folder: .inbox
        )
        await api.setDetail(MailFixtures.detail(a, htmlAvailable: false))
        await api.setDetail(MailFixtures.detail(b, htmlAvailable: false))
    }

    static func mailbox(_ id: String) -> Mailbox {
        Mailbox(
            id: id,
            address: "\(id)@example.com",
            addresses: [],
            displayName: id,
            isActive: true,
            accessLevel: .manager,
            createdAt: MailFixtures.epoch,
            updatedAt: MailFixtures.epoch
        )
    }
}

/// Polls with early exit — never "sleep then assert".
@MainActor
private func wait(
    _ description: Comment,
    timeout: Duration = .seconds(2),
    until condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("Timed out waiting: \(description)")
}

@MainActor
@Suite struct MailViewModelSyncEventTests {
    /// Fails if the view-model reloads slices speculatively on any `.changed`
    /// event: the mailbox-B change must resolve to a row outside the selected
    /// scope and reload nothing.
    @Test func changeInAnotherMailboxDoesNotReloadTheSelectedList() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()
        let baseline = harness.model.conversationReloadCount
        #expect(harness.model.conversations.map(\.id) == ["t1"])

        // Change the cached row behind the view-model's back; only a real reload
        // can make the new subject visible.
        let updated = MailFixtures.message(id: "m1", threadID: "t1", mailboxID: "mbA", subject: "Changed")
        try await harness.store.upsertMessages([updated], accountID: "acct")
        try await harness.store.upsertConversations(
            [MailFixtures.conversation(updated)], accountID: "acct", mailboxID: "mbA", folder: .inbox
        )

        harness.events.yield(.changed(ChangeSet(updated: ["m2"])))
        harness.events.yield(.changed(ChangeSet(updated: ["m1"])))
        try await wait("the in-scope change to land") {
            harness.model.conversations.first?.latest.subject == "Changed"
        }
        // Events are consumed in order, so the mailbox-B event was already
        // processed: exactly one reload means it caused none.
        #expect(harness.model.conversationReloadCount == baseline + 1)
    }

    /// Fails if a change touching a message in the open thread is ignored (stale
    /// reading pane) or if an unrelated message reloads the thread anyway.
    @Test func changeInSelectedThreadReloadsTheThread() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()
        harness.model.selectedThreadID = "t1"
        try await wait("the thread to load") { harness.model.threadMessages.count == 1 }
        let baseline = harness.model.threadReloadCount

        // A second message joins the open thread.
        let sibling = MailFixtures.message(
            id: "m1b", threadID: "t1", mailboxID: "mbA", subject: "Reply", date: MailFixtures.epoch.addingTimeInterval(60)
        )
        try await harness.store.upsertMessages([sibling], accountID: "acct")

        harness.events.yield(.changed(ChangeSet(updated: ["m2"])))
        harness.events.yield(.changed(ChangeSet(inserted: ["m1b"])))
        try await wait("the thread to pick up the new message") { harness.model.threadMessages.count == 2 }
        #expect(harness.model.threadReloadCount == baseline + 1)
    }
}

@MainActor
@Suite struct MailViewModelActionTests {
    /// Fails if the optimistic archive is not visible until the next poll, or if
    /// a rejected archive leaves the row hidden (the revert path).
    @Test func archiveHidesTheRowAndAFailedArchiveRestoresIt() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()
        #expect(harness.model.conversations.map(\.id) == ["t1"])

        await harness.model.perform(.archive, onThread: "t1")
        #expect(harness.model.conversations.isEmpty)
        #expect(await harness.api.actionCount("archive", on: "t1") == 1)

        // Undo the local move so the second attempt starts from the inbox again.
        let restored = MailFixtures.message(id: "m1", threadID: "t1", mailboxID: "mbA")
        try await harness.store.upsertMessages([restored], accountID: "acct")
        try await harness.store.upsertConversations(
            [MailFixtures.conversation(restored)], accountID: "acct", mailboxID: "mbA", folder: .inbox
        )
        await harness.model.reloadConversations()
        #expect(harness.model.conversations.map(\.id) == ["t1"])

        await harness.api.setActionError(.server(code: "boom", message: "nope"))
        await harness.model.perform(.archive, onThread: "t1")
        #expect(harness.model.conversations.map(\.id) == ["t1"])
        #expect(harness.model.actionError != nil)
    }
}

@MainActor
@Suite struct MailViewModelMarkReadTests {
    /// Fails if the dwell task is not cancelled when the selection moves: with a
    /// live task the await below would run the full delay and then mark `m1`
    /// read.
    @Test func switchingBeforeTheDwellElapsesLeavesTheMessageUnread() async throws {
        let harness = try await Harness.make(markReadDelay: .milliseconds(400))
        try await harness.seedTwoMailboxes()
        await harness.model.start()
        harness.model.selectedMessageID = "m1"
        let dwell = harness.model.markReadTask

        harness.model.selectedMessageID = "m2"
        await dwell?.value

        #expect(await harness.api.actionCount("read", on: "m1") == 0)
        #expect(try await harness.store.message(id: "m1")?.isUnread == true)
    }

    /// Fails if a message that holds the selection past the dwell is never marked
    /// read (the whole point of the timer).
    @Test func holdingTheSelectionMarksTheMessageRead() async throws {
        let harness = try await Harness.make(markReadDelay: .zero)
        try await harness.seedTwoMailboxes()
        await harness.model.start()
        harness.model.selectedMessageID = "m1"
        await harness.model.markReadTask?.value

        #expect(await harness.api.actionCount("read", on: "m1") == 1)
        #expect(try await harness.store.message(id: "m1")?.isUnread == false)
    }
}

@MainActor
@Suite struct MailViewModelSearchTests {
    /// Fails if search filters the source of truth instead of the presented list:
    /// selection must survive a query that excludes the selected row.
    @Test func searchDoesNotDropTheSelectedConversation() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()
        harness.model.selectedThreadID = "t1"

        harness.model.searchQuery = "zzz-no-match"
        #expect(harness.model.conversations.isEmpty)
        #expect(harness.model.selectedThreadID == "t1")
        #expect(harness.model.selectedConversation?.id == "t1")
    }
}
