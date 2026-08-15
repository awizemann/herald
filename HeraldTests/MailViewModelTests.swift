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
    /// Drilling in is EXPLICIT. Selecting a row — all an arrow key does — only
    /// previews the conversation's latest message; the middle column stays on the
    /// list. Fails if selection alone drills in (arrowing past a long thread would
    /// yank the user into it), or if an explicit open does nothing, or if a
    /// single-message row can be drilled into at all.
    @Test func onlyMultiMessageConversationsDrillIn() async throws {
        let harness = try await Harness.make()
        try await harness.seedTwoMailboxes()
        try await harness.seedMultiMessageThread()
        harness.model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await harness.model.start()

        // Arrowing onto a two-message thread: selected and previewed, NOT drilled.
        harness.model.selectedThreadID = "t9"
        #expect(harness.model.isShowingThread == false, "an arrow-key selection drilled in")
        try await wait("the thread to load for the preview") { harness.model.threadMessages.count == 2 }
        #expect(harness.model.selectedMessageID == "m9b", "the preview is the latest message")

        // ⏎ / the chevron / a click: now it drills.
        harness.model.openSelectedThread()
        #expect(harness.model.isShowingThread)

        // Arrowing on to a one-message row leaves the thread, and it cannot be
        // drilled into either.
        harness.model.selectedThreadID = "t1"
        #expect(harness.model.isShowingThread == false)
        harness.model.openSelectedThread()
        #expect(harness.model.isShowingThread == false)
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

    /// The chip is text on a neutral surface — VoiceOver reads none of it. Fails
    /// if the attribution is left out of the row's spoken summary, or if it is
    /// spoken when a specific mailbox is picked (where the view passes nil).
    @Test func theRowSummarySpeaksTheMailboxOnlyWhenItIsGiven() {
        let row = MailFixtures.conversation(
            MailFixtures.message(id: "m1", threadID: "t1", subject: "Standup")
        )
        #expect(ConversationRow.accessibilitySummary(for: row, mailboxName: "Support").contains("in Support"))
        #expect(ConversationRow.accessibilitySummary(for: row).contains("in ") == false)

        let message = MailFixtures.message(id: "m1", threadID: "t1", subject: "Standup")
        #expect(ThreadMessageRow.accessibilitySummary(for: message, mailboxName: "Support").contains("in Support"))
        #expect(ThreadMessageRow.accessibilitySummary(for: message).contains("in ") == false)
    }
}
