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

    /// Adds thread `t3`/`m3` to mailbox A's ARCHIVED scope, so a folder switch
    /// actually changes which rows the list should show.
    func seedArchivedThread() async throws {
        let archived = MailFixtures.message(
            id: "m3", threadID: "t3", mailboxID: "mbA", folder: .archived, subject: "Filed"
        )
        try await store.upsertMessages([archived], accountID: "acct")
        try await store.upsertConversations(
            [MailFixtures.conversation(archived)], accountID: "acct", mailboxID: "mbA", folder: .archived
        )
    }

    /// Three inbox threads in mailbox A, newest first as the list orders them:
    /// t3, t2, t1. Enough rows that "the next row" and "the previous row" are
    /// different answers.
    func seedThreeInboxThreads() async throws {
        try await store.upsertMailboxes([Self.mailbox("mbA")], accountID: "acct")
        let messages = (1...3).map { index in
            MailFixtures.message(
                id: "m\(index)",
                threadID: "t\(index)",
                mailboxID: "mbA",
                subject: "Thread \(index)",
                date: MailFixtures.epoch.addingTimeInterval(TimeInterval(index) * 60)
            )
        }
        try await store.upsertMessages(messages, accountID: "acct")
        try await store.upsertConversations(
            messages.map { MailFixtures.conversation($0) },
            accountID: "acct",
            mailboxID: "mbA",
            folder: .inbox
        )
        for message in messages { await api.setDetail(MailFixtures.detail(message, htmlAvailable: false)) }
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
func wait(
    _ description: Comment,
    timeout: Duration = .seconds(2),
    until condition: @MainActor () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
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
        #expect(harness.model.presentedConversations.map(\.id) == ["t1"])

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
            harness.model.presentedConversations.first?.latest.subject == "Changed"
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
        #expect(harness.model.presentedConversations.map(\.id) == ["t1"])

        await harness.model.perform(.archive, onThread: "t1")
        #expect(harness.model.presentedConversations.isEmpty)
        #expect(await harness.api.actionCount("archive", on: "t1") == 1)

        // Undo the local move so the second attempt starts from the inbox again.
        let restored = MailFixtures.message(id: "m1", threadID: "t1", mailboxID: "mbA")
        try await harness.store.upsertMessages([restored], accountID: "acct")
        try await harness.store.upsertConversations(
            [MailFixtures.conversation(restored)], accountID: "acct", mailboxID: "mbA", folder: .inbox
        )
        await harness.model.reloadConversations()
        #expect(harness.model.presentedConversations.map(\.id) == ["t1"])

        await harness.api.setActionError(.server(code: "boom", message: "nope"))
        await harness.model.perform(.archive, onThread: "t1")
        #expect(harness.model.presentedConversations.map(\.id) == ["t1"])
        #expect(harness.model.actionError != nil)
    }
}

@MainActor
@Suite struct MailViewModelSelectionTests {
    /// Two folder switches in a row used to leave the first reload running: it
    /// finishes against the OLD scope and assigns its rows while the selection has
    /// already moved on. Fails if the superseded reload is merely replaced rather
    /// than cancelled, or if the final list does not match the final selection.
    @Test func switchingFoldersCancelsTheSupersededReload() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        try await harness.seedArchivedThread()

        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        let superseded = try #require(harness.model.reloadTask)
        harness.model.selection = .init(mailboxID: "mbA", folder: .archived)
        #expect(superseded.isCancelled, "The superseded reload was left running to finish last")

        await (try #require(harness.model.reloadTask)).value
        // Selection survives, and the list is the one the selection asks for.
        #expect(harness.model.selection.folder == .archived)
        #expect(harness.model.presentedConversations.map(\.id) == ["t3"])
    }

    /// The server 400s a conversation action with no folder, and answers the wrong
    /// thing when given the wrong one. Fails if the view-model sends a hardcoded
    /// (or stale) folder rather than the selected scope.
    @Test func conversationActionsCarryTheSelectedFolder() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        try await harness.seedArchivedThread()
        harness.model.selection = .init(mailboxID: "mbA", folder: .archived)
        await harness.model.start()
        #expect(harness.model.presentedConversations.map(\.id) == ["t3"])

        await harness.model.perform(.read, onThread: "t3")
        #expect(await harness.api.actionFolders("read", on: "t3") == [.archived])
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
        // #require, not `dwell?`: if the task were nil the optional await is a
        // no-op and this test would pass without ever running the dwell timer.
        let dwell = try #require(harness.model.markReadTask)

        harness.model.selectedMessageID = "m2"
        await dwell.value

        #expect(await harness.api.actionCount("read", on: "m1") == 0)
        #expect(try await harness.store.message(id: "m1", accountID: "acct")?.isUnread == true)
    }

    /// Fails if a message that holds the selection past the dwell is never marked
    /// read (the whole point of the timer).
    @Test func holdingTheSelectionMarksTheMessageRead() async throws {
        let harness = try await Harness.make(markReadDelay: .zero)
        try await harness.seedTwoMailboxes()
        await harness.model.start()
        harness.model.selectedMessageID = "m1"
        await (try #require(harness.model.markReadTask)).value

        #expect(await harness.api.actionCount("read", on: "m1") == 1)
        #expect(try await harness.store.message(id: "m1", accountID: "acct")?.isUnread == false)
    }
}

@MainActor
@Suite struct MailViewModelSelectionAdvanceTests {
    /// Archiving the row you are reading used to leave `selectedThreadID` pointing
    /// at a row the list no longer shows: the reading pane kept the archived
    /// message and the next ⌘⇧A acted on it again. Fails if the selection does not
    /// move to the row that took its place.
    @Test func archivingTheSelectedRowSelectsTheNextOne() async throws {
        let harness = try await Harness.make()
        try await harness.seedThreeInboxThreads()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()
        #expect(harness.model.presentedConversations.map(\.id) == ["t3", "t2", "t1"])

        harness.model.selectedThreadID = "t2" // The middle row.
        await harness.model.perform(.archive, onThread: "t2")

        #expect(harness.model.presentedConversations.map(\.id) == ["t3", "t1"])
        #expect(harness.model.selectedThreadID == "t1", "The selection did not follow the archive")
    }

    /// The end-of-list case: there is no following row, so the selection has to
    /// fall back to the last one rather than to nothing.
    @Test func archivingTheLastRowSelectsThePreviousOne() async throws {
        let harness = try await Harness.make()
        try await harness.seedThreeInboxThreads()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()

        harness.model.selectedThreadID = "t1" // Oldest, so last in the list.
        await harness.model.perform(.trash, onThread: "t1")

        #expect(harness.model.selectedThreadID == "t2")
    }

    /// Fails if the selection moves on ANY action rather than only on one that
    /// removes the row: marking a thread read must not jump the user elsewhere.
    @Test func markingReadLeavesTheSelectionAlone() async throws {
        let harness = try await Harness.make()
        try await harness.seedThreeInboxThreads()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()

        harness.model.selectedThreadID = "t2"
        await harness.model.perform(.read, onThread: "t2")

        #expect(harness.model.selectedThreadID == "t2")
    }
}

@MainActor
@Suite struct MailViewModelFilterTests {
    /// The presented list used to be a computed property: it re-filtered — and
    /// re-lowercased every subject, sender and snippet — on every read, and the
    /// list's body reads it on every unrelated `@Observable` change. Fails if an
    /// error, a selection or a no-op search assignment re-filters, or if a real
    /// search change does not.
    @Test func onlyTheFiltersOwnInputsRecomputeTheList() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()
        let baseline = harness.model.filterCount

        harness.model.actionError = "something went wrong"
        harness.model.selectedThreadID = "t1"
        harness.model.composeRequest = nil
        harness.model.searchQuery = "" // Assigned, but unchanged.
        #expect(harness.model.filterCount == baseline, "An unrelated change re-filtered the whole list")

        harness.model.searchQuery = "original"
        #expect(harness.model.filterCount == baseline + 1)
        #expect(harness.model.presentedConversations.map(\.id) == ["t1"])

        harness.model.searchQuery = "zzz-no-match"
        #expect(harness.model.filterCount == baseline + 2)
        #expect(harness.model.presentedConversations.isEmpty)
    }
}

@MainActor
@Suite struct ConversationRowAccessibilityTests {
    /// VoiceOver's only route to unread/starred/attachment state is this string —
    /// on screen they are a dot, a bold weight and a paperclip, none of which says
    /// anything out loud. Fails if any of them is dropped from the summary.
    @Test func theRowSummaryNamesEveryStateTheIconsCarry() {
        let plain = ConversationSummary(
            latest: MailFixtures.message(id: "m1", threadID: "t1", subject: "Standup"),
            isStarred: false,
            messageCount: 1,
            unreadCount: 0
        )
        let quiet = ConversationRow.accessibilitySummary(for: plain)
        #expect(quiet.contains("Standup"))
        #expect(quiet.contains("unread") == false)
        #expect(quiet.contains("starred") == false)
        #expect(quiet.contains("has attachments") == false)

        let flagged = ConversationSummary(
            latest: MailFixtures.message(
                id: "m1", threadID: "t1", subject: "Standup", hasAttachments: true
            ),
            isStarred: true,
            messageCount: 3,
            unreadCount: 2
        )
        let loud = ConversationRow.accessibilitySummary(for: flagged)
        #expect(loud.contains("unread"))
        #expect(loud.contains("starred"))
        #expect(loud.contains("has attachments"))
        #expect(loud.contains("3 messages"))
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
        #expect(harness.model.presentedConversations.isEmpty)
        #expect(harness.model.selectedThreadID == "t1")
        #expect(harness.model.selectedConversation?.id == "t1")
    }
}
