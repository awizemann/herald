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

    /// A two-message thread (`t9`), so "drills in" and "does not drill in" are
    /// both reachable from one harness.
    func seedMultiMessageThread() async throws {
        let first = MailFixtures.message(id: "m9a", threadID: "t9", mailboxID: "mbA", subject: "Long thread")
        let second = MailFixtures.message(
            id: "m9b",
            threadID: "t9",
            mailboxID: "mbA",
            subject: "Long thread",
            date: MailFixtures.epoch.addingTimeInterval(120)
        )
        try await store.upsertMessages([first, second], accountID: "acct")
        try await store.upsertConversations(
            [MailFixtures.conversation(second, messageCount: 2)],
            accountID: "acct",
            mailboxID: "mbA",
            folder: .inbox
        )
        await api.setDetail(MailFixtures.detail(first, htmlAvailable: false))
        await api.setDetail(MailFixtures.detail(second, htmlAvailable: false))
    }

    /// The issue-#5 layout: three single-message rows above a two-message
    /// thread — `t1`, `t2`, `t3` newest first, then `t9` (oldest) last.
    func seedSinglesAboveAThread() async throws {
        try await store.upsertMailboxes([Self.mailbox("mbA")], accountID: "acct")
        let singles = (1...3).map { index in
            MailFixtures.message(
                id: "m\(index)",
                threadID: "t\(index)",
                mailboxID: "mbA",
                subject: "Single \(index)",
                date: MailFixtures.epoch.addingTimeInterval(TimeInterval(400 - index * 100))
            )
        }
        let first = MailFixtures.message(
            id: "m9a", threadID: "t9", mailboxID: "mbA", subject: "Long thread",
            date: MailFixtures.epoch
        )
        let second = MailFixtures.message(
            id: "m9b", threadID: "t9", mailboxID: "mbA", subject: "Long thread",
            date: MailFixtures.epoch.addingTimeInterval(50)
        )
        try await store.upsertMessages(singles + [first, second], accountID: "acct")
        try await store.upsertConversations(
            singles.map { MailFixtures.conversation($0) }
                + [MailFixtures.conversation(second, messageCount: 2)],
            accountID: "acct",
            mailboxID: "mbA",
            folder: .inbox
        )
        for message in singles { await api.setDetail(MailFixtures.detail(message, htmlAvailable: false)) }
    }

    /// A two-message thread that already lives in the TRASH listing scope, so
    /// "archive from the Trash" is reachable.
    func seedTrashedThread() async throws {
        try await store.upsertMailboxes([Self.mailbox("mbA")], accountID: "acct")
        let first = MailFixtures.message(
            id: "m7a", threadID: "t7", mailboxID: "mbA", folder: .trash, subject: "Deleted"
        )
        let second = MailFixtures.message(
            id: "m7b", threadID: "t7", mailboxID: "mbA", folder: .trash, subject: "Deleted",
            date: MailFixtures.epoch.addingTimeInterval(60)
        )
        try await store.upsertMessages([first, second], accountID: "acct")
        try await store.upsertConversations(
            [MailFixtures.conversation(second, messageCount: 2)],
            accountID: "acct",
            mailboxID: "mbA",
            folder: .trash
        )
        await api.setDetail(MailFixtures.detail(first, htmlAvailable: false))
        await api.setDetail(MailFixtures.detail(second, htmlAvailable: false))
    }

    /// One unread starred conversation in mailbox A's STARRED listing scope.
    func seedStarredThread() async throws {
        let starred = MailFixtures.message(
            id: "m4", threadID: "t4", mailboxID: "mbA", subject: "Pinned", starred: true
        )
        try await store.upsertMessages([starred], accountID: "acct")
        try await store.upsertConversations(
            [MailFixtures.conversation(starred)], accountID: "acct", mailboxID: "mbA", folder: .starred
        )
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

    /// Real-server regression (2026-08-15): after the FIRST sync of an account the
    /// sidebar stayed empty, because a newly inserted mailbox id is not yet in
    /// `mailboxes`, so the old `mailboxes.contains(id)` check never asked for a
    /// reload. Fails on that code: `mailboxes` stays empty forever.
    @Test func aFreshlyInsertedMailboxShowsUpInTheSidebar() async throws {
        let harness = try await Harness.make()
        await harness.model.start()
        #expect(harness.model.mailboxes.isEmpty)

        try await harness.store.upsertMailboxes([Harness.mailbox("mbNew")], accountID: "acct")
        harness.events.yield(.changed(ChangeSet(inserted: ["mbNew"])))
        try await wait("the new mailbox to appear") {
            harness.model.mailboxes.map(\.id) == ["mbNew"]
        }
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
        // The wire id is a MEMBER MESSAGE id, not the thread id: the server
        // resolves the mailbox for its access check from it (see the API contract
        // note). Asserting "t1" here was left over from before that fix.
        #expect(await harness.api.actionCount("archive", on: "m1") == 1)
        #expect(await harness.api.actionCount("archive", on: "t1") == 0)

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
@Suite struct MailViewModelTrashVisibilityTests {
    /// Issue #6: a deleted mail did not show up in Trash. The optimistic action
    /// moved every MESSAGE to the trash folder but created no conversation row in
    /// the `trash` LISTING scope, so the Trash list queried the store and found
    /// nothing until a later poll happened to list one. Fails on the pre-fix
    /// store: the trash scope stays empty.
    @Test func aJustDeletedThreadShowsUpInTheTrashList() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()

        await harness.model.perform(.trash, onThread: "t1")
        #expect(harness.model.presentedConversations.isEmpty, "the row must leave the inbox")

        harness.model.selection = .init(mailboxID: "mbA", folder: .trash)
        await (try #require(harness.model.reloadTask)).value
        #expect(harness.model.presentedConversations.map(\.id) == ["t1"])
    }

    /// A server that rejects the delete must not leave the invented Trash row
    /// behind — the thread would then be listed in two folders at once.
    @Test func aRejectedDeleteLeavesNoRowInTheTrashList() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()

        await harness.api.setActionError(.server(code: "boom", message: "nope"))
        await harness.model.perform(.trash, onThread: "t1")
        #expect(harness.model.presentedConversations.map(\.id) == ["t1"], "the inbox row must come back")

        harness.model.selection = .init(mailboxID: "mbA", folder: .trash)
        await (try #require(harness.model.reloadTask)).value
        #expect(harness.model.presentedConversations.isEmpty)
    }

    /// Issue #6, second half: Refresh appeared to do nothing. The view-model only
    /// reacted to ChangeSets, so a pass whose changes resolved to nothing the
    /// current scope was keyed by left the list exactly as it was — while leaving
    /// the folder and coming back showed the new rows. Fails on the pre-fix code:
    /// the row written behind the view-model's back never appears.
    @Test func refreshReloadsThePresentedScopeWhenThePassFinishes() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()
        #expect(harness.model.presentedConversations.map(\.id) == ["t1"])

        // Exactly what a sync pass does — with no `.changed` event to react to.
        let arrival = MailFixtures.message(
            id: "m5", threadID: "t5", mailboxID: "mbA", subject: "New",
            date: MailFixtures.epoch.addingTimeInterval(600)
        )
        try await harness.store.upsertMessages([arrival], accountID: "acct")
        try await harness.store.upsertConversations(
            [MailFixtures.conversation(arrival)], accountID: "acct", mailboxID: "mbA", folder: .inbox
        )

        await harness.model.refresh()
        harness.events.yield(.finished)

        try await wait("the finished pass to reload the presented scope") {
            harness.model.presentedConversations.map(\.id) == ["t5", "t1"]
        }
        // The badges come from the same reload, one store round trip later.
        try await wait("the unread badges to be recounted") {
            harness.model.unreadCounts[.init(mailboxID: "mbA", folder: .inbox)] == 2
        }
    }

    /// A `.finished` that no Refresh asked for must NOT reload: the change
    /// detection the store does is the whole reason the list is not rebuilt on
    /// every poll. Fails if the reload is unconditional.
    @Test func aRoutinePassDoesNotReloadThePresentedScope() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()
        let baseline = harness.model.conversationReloadCount

        harness.events.yield(.began)
        harness.events.yield(.finished)
        try await wait("the pass to be recorded") { harness.model.lastSyncedAt != nil }
        #expect(harness.model.conversationReloadCount == baseline)
    }

    /// The sync-driven half of issue #6: the pass creates the Trash-scope row
    /// itself and reports a THREAD id, which resolves to no cached message. That
    /// used to fall through to "must be a new mailbox" and reload nothing the
    /// user could see. Fails on the pre-fix code: the Trash list stays empty.
    @Test func aNewConversationRowInTheOpenScopeReloadsTheList() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        harness.model.selection = .init(mailboxID: "mbA", folder: .trash)
        await harness.model.start()
        #expect(harness.model.presentedConversations.isEmpty)

        let deleted = MailFixtures.message(
            id: "m6", threadID: "t6", mailboxID: "mbA", folder: .trash, subject: "Gone"
        )
        try await harness.store.upsertMessages([deleted], accountID: "acct")
        try await harness.store.upsertConversations(
            [MailFixtures.conversation(deleted)], accountID: "acct", mailboxID: "mbA", folder: .trash
        )
        harness.events.yield(.changed(ChangeSet(inserted: ["t6"])))

        try await wait("the new trash row to be listed") {
            harness.model.presentedConversations.map(\.id) == ["t6"]
        }
    }

    /// A message that RESOLVES (so it is not the "unknown id" branch) can still
    /// name a mailbox created server-side since the last mailbox reload. Its row
    /// then draws with no mailbox chip, and the list caches that shorter row.
    /// Fails on the pre-fix code: only the unresolvable branch reloaded mailboxes.
    @Test func aNewMessageInAnUnlistedMailboxReloadsTheMailboxes() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        harness.model.selection = .init(mailboxID: nil, folder: .inbox)
        await harness.model.start()
        #expect(harness.model.mailboxName(for: "mbC") == nil)

        try await harness.store.upsertMailboxes([Harness.mailbox("mbC")], accountID: "acct")
        let fresh = MailFixtures.message(id: "m9", threadID: "t9", mailboxID: "mbC", subject: "New")
        try await harness.store.upsertMessages([fresh], accountID: "acct")
        try await harness.store.upsertConversations(
            [MailFixtures.conversation(fresh)], accountID: "acct", mailboxID: "mbC", folder: .inbox
        )
        harness.events.yield(.changed(ChangeSet(inserted: ["m9"])))

        try await wait("the new row to be listed") {
            harness.model.presentedConversations.contains { $0.id == "t9" }
        }
        #expect(harness.model.mailboxName(for: "mbC") != nil, "the row's chip needs the mailbox name on first render")
    }
}

@MainActor
@Suite struct MailViewModelTrashActionTests {
    /// Issue #7/#8: the Trash needs a real "Put back". Before upstream 1.3.4 the
    /// v1 API had no restore, and Herald faked one with a per-message archive —
    /// which put mail the user un-deleted into the Archive, not back where it
    /// came from. `restore` is now one CONVERSATION call carrying `folder: trash`
    /// (the server no-ops without it), and the row leaves the Trash list.
    @Test func putBackFromTheTrashIsOneConversationRestore() async throws {
        let harness = try await Harness.make()
        try await harness.seedTrashedThread()
        harness.model.selection = .init(mailboxID: "mbA", folder: .trash)
        await harness.model.start()
        #expect(harness.model.presentedConversations.map(\.id) == ["t7"])
        #expect(harness.model.restoreAction == .restore)
        #expect(harness.model.restoreActionTitle == "Put Back")

        await harness.model.perform(.restore, onThread: "t7")

        #expect(await harness.api.conversationActionIDs("restore") == ["m7b"])
        #expect(await harness.api.messageActionIDs("restore").isEmpty)
        #expect(await harness.api.actionFolders("restore", on: "m7b") == [.trash])
        #expect(harness.model.presentedConversations.isEmpty, "the thread must leave the Trash list")
        #expect(harness.model.actionError == nil)
    }

    /// The Archive folder gets the mirror verb, and it must go down the
    /// CONVERSATION route carrying `folder: archived` — the server pushes
    /// `1 = 0` and matches nothing when the body's folder disagrees, so a
    /// dropped or wrong folder is a silent no-op the user reads as a bug.
    @Test func theArchiveFolderUnarchivesThroughTheConversationRoute() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        try await harness.seedArchivedThread()
        harness.model.selection = .init(mailboxID: "mbA", folder: .archived)
        await harness.model.start()
        #expect(harness.model.restoreAction == .unarchive)
        #expect(harness.model.restoreActionTitle == "Move to Inbox")
        // Archiving what is already archived is a server no-op, so it is not offered.
        #expect(harness.model.offersArchiveAction == false)
        #expect(harness.model.presentedConversations.map(\.id) == ["t3"])

        await harness.model.perform(.unarchive, onThread: "t3")

        #expect(await harness.api.conversationActionIDs("unarchive") == ["m3"])
        #expect(await harness.api.messageActionIDs("unarchive").isEmpty)
        #expect(await harness.api.actionFolders("unarchive", on: "m3") == [.archived])
        #expect(harness.model.presentedConversations.isEmpty, "the thread must leave the Archive list")
        #expect(harness.model.actionError == nil)
    }

    /// Outside the Trash the conversation route is still the right one: one call
    /// for the whole thread, not one per message.
    @Test func archiveOutsideTheTrashStaysAConversationCall() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()

        await harness.model.perform(.archive, onThread: "t1")

        #expect(await harness.api.conversationActionIDs("archive") == ["m1"])
        #expect(await harness.api.messageActionIDs("archive").isEmpty)
    }

    /// Trashing what is already in the Trash is a server no-op, so Herald must
    /// not send it — and must not move the row locally either.
    @Test func trashInTheTrashIsNotSentAtAll() async throws {
        let harness = try await Harness.make()
        try await harness.seedTrashedThread()
        harness.model.selection = .init(mailboxID: "mbA", folder: .trash)
        await harness.model.start()

        await harness.model.perform(.trash, onThread: "t7")

        #expect(await harness.api.actionCount("trash", on: "m7b") == 0)
        #expect(harness.model.presentedConversations.map(\.id) == ["t7"])
        #expect(harness.model.offersTrashAction == false)
        // The Trash offers Put Back instead of Archive.
        #expect(harness.model.offersArchiveAction == false)
        #expect(harness.model.restoreActionTitle == "Put Back")
    }

    /// A 200 that reports `affected: 0` is the server saying it changed nothing.
    /// Waiting for a later sync pass to heal the optimistic move is what made the
    /// mail "lost" in the meantime. Fails on the pre-fix service, which treated
    /// any non-throwing response as success and left the row archived locally.
    @Test func aConversationActionThatAffectedNothingRevertsImmediately() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()
        await harness.api.setConversationAffected(0)

        await harness.model.perform(.archive, onThread: "t1")

        #expect(harness.model.presentedConversations.map(\.id) == ["t1"], "the row was not put back")
        #expect(try await harness.store.message(id: "m1", accountID: "acct")?.folder == .inbox)
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
        // `m3` is t3's only message, and the member message id is what goes on
        // the wire; the FOLDER is what this test is about.
        #expect(await harness.api.actionFolders("read", on: "m3") == [.archived])
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

    /// Issue #5: with a multi-message thread below the selected row, deleting the
    /// selected row advanced the selection onto the thread — and the `didSet`
    /// that drills into a multi-message selection then dropped the user INSIDE
    /// it. Fails on the pre-fix code, where `isShowingThread` comes back true:
    /// a programmatic advance must select without drilling.
    @Test func advancingPastADeletedRowSelectsTheThreadWithoutOpeningIt() async throws {
        let harness = try await Harness.make()
        try await harness.seedSinglesAboveAThread()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()
        #expect(harness.model.presentedConversations.map(\.id) == ["t1", "t2", "t3", "t9"])

        harness.model.selectedThreadID = "t3" // The row directly above the thread.
        #expect(harness.model.isShowingThread == false)

        await harness.model.perform(.archive, onThread: "t3")

        #expect(harness.model.selectedThreadID == "t9", "the selection did not follow the archive")
        #expect(
            harness.model.isShowingThread == false,
            "a programmatic advance drilled into the thread the user never opened"
        )
    }

    /// The user path still drills: the fix must be scoped to the programmatic
    /// advance, not turn selection-drilling off everywhere.
    @Test func aUserSelectionStillDrillsAfterAnAdvance() async throws {
        let harness = try await Harness.make()
        try await harness.seedSinglesAboveAThread()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()
        harness.model.selectedThreadID = "t3"
        await harness.model.perform(.archive, onThread: "t3")
        #expect(harness.model.isShowingThread == false)

        harness.model.selectedThreadID = "t1"
        harness.model.selectedThreadID = "t9" // The user arrows onto it themselves.
        #expect(harness.model.isShowingThread, "selecting a multi-message thread must still drill in")
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

@MainActor
@Suite struct MailViewModelStatusSlotTests {
    /// The sidebar's status line used to render `EmptyView()` when idle, so it
    /// appeared and vanished on every poll and pushed the folder list down and
    /// back. The slot is only jump-free if it ALWAYS has something to draw.
    /// Fails the moment any status maps to an empty string.
    @Test func everyStatusHasSomethingToSayInTheSlot() {
        let states: [MailViewModel.SyncStatus] = [.idle, .syncing, .failed("boom"), .needsReauth]
        for status in states {
            #expect(
                MailViewModel.statusDescription(for: status, lastSyncedAt: nil).isEmpty == false,
                "\(status) left the fixed-height status slot empty"
            )
        }
        #expect(MailViewModel.statusDescription(for: .syncing, lastSyncedAt: nil) == "Syncing…")
        #expect(MailViewModel.statusDescription(for: .idle, lastSyncedAt: nil) == "Up to date")
    }

    /// Idle-with-a-history is the common case, and it must say WHEN. Fails if the
    /// finished event stops stamping `lastSyncedAt` (the slot would then be stuck
    /// on "Up to date" forever) or if the idle text ignores the stamp.
    @Test func afinishedPassStampsTheSlotWithTheTime() async throws {
        let harness = try await Harness.make()
        await harness.model.start()
        #expect(harness.model.lastSyncedAt == nil)

        harness.events.yield(.began)
        harness.events.yield(.finished)
        try await wait("the pass to be recorded") { harness.model.lastSyncedAt != nil }

        let text = MailViewModel.statusDescription(
            for: harness.model.status,
            lastSyncedAt: harness.model.lastSyncedAt
        )
        #expect(text.hasPrefix("Updated "), "idle after a real pass should carry the time, got \(text)")
    }
}

@MainActor
@Suite struct MailViewModelMailboxPickerTests {
    /// The picker replaced one sidebar section per mailbox, so switching mailbox
    /// must be a scope change — not a jump back to the inbox. Fails if the folder
    /// is dropped when the picker writes `mailboxID`.
    @Test func pickingAMailboxKeepsTheFolder() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        try await harness.seedArchivedThread()
        await harness.model.start()
        harness.model.selection = .init(mailboxID: nil, folder: .archived)

        // Exactly what the picker's binding does.
        harness.model.selection = .init(mailboxID: "mbA", folder: harness.model.selection.folder)

        #expect(harness.model.selection.folder == .archived)
        await (try #require(harness.model.reloadTask)).value
        #expect(harness.model.presentedConversations.map(\.id) == ["t3"])
    }

    /// The picker's labels are the only place a mailbox's address and its unread
    /// count are shown now. Fails if either is dropped, or if a zero count starts
    /// rendering as a noisy "(0)".
    @Test func pickerLabelsCarryTheAddressAndTheUnreadCount() {
        let mailbox = Harness.mailbox("mbA")
        #expect(MailViewModel.pickerLabel(for: mailbox, unread: 3) == "mbA — mbA@example.com (3)")
        #expect(MailViewModel.pickerLabel(for: mailbox, unread: 0) == "mbA — mbA@example.com")
        #expect(MailViewModel.allMailboxesPickerLabel(unread: 7) == "All mailboxes (7)")
        #expect(MailViewModel.allMailboxesPickerLabel(unread: 0) == "All mailboxes")
    }

    /// The sidebar draws a badge per folder now, not just the inbox. Fails if the
    /// counted scopes go back to inbox-only — Starred and the rest would show a
    /// permanent 0 whatever the store holds.
    @Test func everySidebarFolderOfThePickedScopeIsCounted() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        try await harness.seedStarredThread()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()

        #expect(harness.model.unreadCounts[.init(mailboxID: "mbA", folder: .starred)] == 1)
        #expect(harness.model.unreadCounts[.init(mailboxID: "mbA", folder: .inbox)] == 1)
    }

    /// Starred is a real listing scope on the server, so selecting it has to
    /// resolve to the starred rows. Fails if `.starred` is filtered out by the
    /// presentation rule (`belongs(_:to:)`) or never loaded at all.
    @Test func theStarredScopeShowsStarredConversations() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        try await harness.seedStarredThread()
        harness.model.selection = .init(mailboxID: "mbA", folder: .starred)
        await harness.model.start()

        #expect(harness.model.presentedConversations.map(\.id) == ["t4"])
    }
}

@MainActor
@Suite struct MailViewModelThreadDrillInTests {
    /// Owner decision 2026-08-16: SELECTING a multi-message conversation drills
    /// straight into its message list; a single-message one only previews. Fails
    /// if selection no longer drills, if the drilled thread doesn't load with the
    /// latest message selected, or if a single-message row can be drilled into.
    @Test func onlyMultiMessageConversationsDrillIn() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        try await harness.seedMultiMessageThread()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()

        // Selecting a two-message thread drills in and loads it.
        harness.model.selectedThreadID = "t9"
        #expect(harness.model.isShowingThread, "selecting a multi-message thread must drill in")
        try await wait("the thread to load") { harness.model.threadMessages.count == 2 }
        #expect(harness.model.selectedMessageID == "m9b", "the latest message is selected")

        // ⎋ / back leaves it; ⏎ / chevron re-enters without a selection change.
        harness.model.exitThread()
        #expect(harness.model.isShowingThread == false)
        harness.model.openSelectedThread()
        #expect(harness.model.isShowingThread)

        // Arrowing on to a one-message row leaves the thread, and it cannot be
        // drilled into either.
        harness.model.selectedThreadID = "t1"
        #expect(harness.model.isShowingThread == false)
        harness.model.openSelectedThread()
        #expect(harness.model.isShowingThread == false)
    }

    /// Owner rule 2026-08-16: new mail is ALWAYS first — in the conversation list
    /// AND inside a drilled thread — and the newest message is the one auto-selected.
    /// Fails if either list comes back oldest-first, or if the older message is
    /// what gets selected on entry.
    @Test func newestIsFirstInBothListsAndAutoSelectedInTheThread() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        try await harness.seedMultiMessageThread()   // m9a at epoch, m9b at epoch+120s
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()

        // Conversation list: t9's latest (epoch+120) is newer than t1's (epoch) → t9 first.
        #expect(harness.model.presentedConversations.map(\.id) == ["t9", "t1"])

        harness.model.selectedThreadID = "t9"
        try await wait("the thread to load") { harness.model.threadMessages.count == 2 }
        #expect(harness.model.threadMessages.map(\.id) == ["m9b", "m9a"], "thread must be newest-first")
        #expect(harness.model.selectedMessageID == "m9b", "the newest message is auto-selected")
    }

    /// The mouse path: a click both selects and opens — including a click on the
    /// row that is ALREADY selected, where the selection binding reports no change
    /// at all and nothing else would fire.
    @Test func clickingARowOpensItEvenWhenItIsAlreadySelected() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        try await harness.seedMultiMessageThread()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()

        harness.model.openThread("t9")
        #expect(harness.model.selectedThreadID == "t9")
        #expect(harness.model.isShowingThread)

        harness.model.exitThread()
        harness.model.openThread("t9") // the same row, clicked again
        #expect(harness.model.isShowingThread, "re-clicking the selected row did not reopen it")
    }

    /// Backing out (the chevron, ⎋, ⌘[) returns to the list WITHOUT losing the
    /// row — that is the whole reason the drill-in is VM state and not a
    /// NavigationStack push. Fails if `exitThread` clears the selection, or if
    /// re-entering the same row is impossible (its selection never changes, so
    /// nothing else would put the user back).
    @Test func backingOutKeepsTheSelectionAndTheThreadCanBeReEntered() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        try await harness.seedMultiMessageThread()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()
        harness.model.selectedThreadID = "t9"
        try await wait("the thread to load") { harness.model.threadMessages.count == 2 }
        harness.model.openSelectedThread()
        #expect(harness.model.isShowingThread)
        let loads = harness.model.threadReloadCount

        harness.model.exitThread()
        #expect(harness.model.isShowingThread == false)
        #expect(harness.model.selectedThreadID == "t9", "backing out dropped the row")
        #expect(harness.model.threadMessages.count == 2, "backing out threw the loaded thread away")

        harness.model.openSelectedThread()
        #expect(harness.model.isShowingThread)
        #expect(harness.model.threadReloadCount == loads, "re-entering re-fetched a thread it already had")
    }

    /// A single-message row can never be drilled into, from the keyboard either.
    @Test func returnDoesNotDrillIntoASingleMessageConversation() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()
        harness.model.selectedThreadID = "t1"

        harness.model.openSelectedThread()
        #expect(harness.model.isShowingThread == false)
    }

    /// Changing scope while drilled in has to come back out: the thread belongs to
    /// the folder the user just left. Fails if the flag survives a scope change
    /// and the middle column shows another folder's thread.
    @Test func changingScopeLeavesTheThread() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        try await harness.seedArchivedThread()
        try await harness.seedMultiMessageThread()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()
        harness.model.openThread("t9")
        #expect(harness.model.isShowingThread)

        harness.model.selection = .init(mailboxID: "mbA", folder: .archived)
        #expect(harness.model.isShowingThread == false)
        #expect(harness.model.selectedThreadID == nil)
    }

    /// The dwell mark-read rule is per MESSAGE, and inside a drilled thread the
    /// message selection is the only thing that moves. Fails if drilling in
    /// bypasses the dwell timer for the messages the user actually reads.
    @Test func theDwellRuleStillAppliesToAMessagePickedInsideTheThread() async throws {
        let harness = try await Harness.make(markReadDelay: .zero)
        try await harness.seedTwoMailboxes()
        try await harness.seedMultiMessageThread()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()
        harness.model.openThread("t9")
        try await wait("the thread to load") { harness.model.threadMessages.count == 2 }
        #expect(harness.model.isShowingThread)

        harness.model.selectedMessageID = "m9a"
        await (try #require(harness.model.markReadTask)).value

        #expect(await harness.api.actionCount("read", on: "m9a") == 1)
        #expect(try await harness.store.message(id: "m9a", accountID: "acct")?.isUnread == false)
    }
}

@MainActor
@Suite struct MailViewModelMailboxAttributionTests {
    /// Rows in the all-mailboxes scope have to say which mailbox they came from,
    /// and the lookup is a dictionary because the list draws it on EVERY row.
    /// Fails if the index is not rebuilt when mailboxes reload.
    @Test func mailboxNamesResolveAfterTheMailboxListLoads() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        #expect(harness.model.mailboxName(for: "mbA") == nil)

        await harness.model.start()
        #expect(harness.model.mailboxName(for: "mbA") == "mbA")
        #expect(harness.model.mailboxName(for: "nope") == nil)
        #expect(harness.model.mailboxName(for: nil) == nil)
    }

    /// The chip is the row's PRIMARY label now, and VoiceOver reads none of the
    /// chip itself. Fails if the mailbox is left out of the spoken summary, if it
    /// is no longer the FIRST thing spoken (the sender would lead, contradicting
    /// what the row shows), or if it is spoken when a specific mailbox is picked
    /// and the view passes nil.
    @Test func theRowSummaryLeadsWithTheMailboxOnlyWhenItIsGiven() {
        let row = MailFixtures.conversation(
            MailFixtures.message(id: "m1", threadID: "t1", subject: "Standup")
        )
        let attributed = ConversationRow.accessibilitySummary(for: row, mailboxName: "Support")
        #expect(attributed.hasPrefix("Support, "))
        let plain = ConversationRow.accessibilitySummary(for: row)
        #expect(plain.hasPrefix("Support") == false)
        #expect(plain.contains("Support") == false)

        let message = MailFixtures.message(id: "m1", threadID: "t1", subject: "Standup")
        #expect(
            ThreadMessageRow.accessibilitySummary(for: message, mailboxName: "Support")
                .hasPrefix("Support, ")
        )
        #expect(ThreadMessageRow.accessibilitySummary(for: message).contains("Support") == false)
    }
}
