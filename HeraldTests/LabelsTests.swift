import Foundation
import HeraldKit
import Testing
@testable import Herald

/// Records what the view-model asked the sync engine to do.
private actor LabelFakeSync: MailSyncing {
    private(set) var refreshCount = 0
    private(set) var draftRefreshCount = 0
    private(set) var labelRefreshCount = 0
    /// Every value the view-model pushed for the label surface, in order.
    private(set) var labelSurfaceVisibility: [Bool] = []

    func refreshNow() { refreshCount += 1 }
    func refreshDraftsNow() { draftRefreshCount += 1 }
    func refreshLabelsNow() { labelRefreshCount += 1 }
    func setCadence(_ cadence: SyncCadence) {}
    func setLabelSurfaceVisible(_ visible: Bool) { labelSurfaceVisibility.append(visible) }
}

@MainActor
private struct LabelHarness {
    let store: MailStore
    let api: FakeMailAPIClient
    let sync: LabelFakeSync
    let model: MailViewModel

    static let account = "acct"

    static func label(_ id: String, _ name: String, color: LabelColor = .blue) -> MailLabel {
        MailLabel(id: id, name: name, color: color)
    }

    static func make() async throws -> LabelHarness {
        let store = try MailStore.inMemory()
        let api = FakeMailAPIClient()
        let sync = LabelFakeSync()
        let (stream, _) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .unbounded)
        let model = MailViewModel(
            accountID: account,
            accountLabel: "Test",
            api: api,
            store: store,
            actions: MailActionService(api: api, store: store),
            sync: sync,
            events: stream,
            markReadDelay: .seconds(3_600)
        )
        return LabelHarness(store: store, api: api, sync: sync, model: model)
    }

    /// Two threads in two different folders, one label, and the label on the
    /// archived thread only — the shape that separates "listing by label" from
    /// "filtering the folder on screen".
    func seed() async throws {
        let inbox = MailFixtures.message(id: "m1", threadID: "thr_inbox", folder: .inbox)
        let archived = MailFixtures.message(id: "m2", threadID: "thr_archived", folder: .archived)
        try await store.upsertMessages([inbox, archived], accountID: Self.account)
        try await store.upsertConversations(
            [MailFixtures.conversation(inbox)],
            accountID: Self.account, mailboxID: "mbA", folder: .inbox
        )
        try await store.upsertConversations(
            [MailFixtures.conversation(archived)],
            accountID: Self.account, mailboxID: "mbA", folder: .archived
        )
        try await store.replaceLabels(
            [Self.label("lbl_1", "Billing", color: .green), Self.label("lbl_2", "Later", color: .amber)],
            accountID: Self.account
        )
        try await store.replaceAssignments(
            labelID: "lbl_1",
            messages: [LabelRowKey(messageID: "m2", threadID: "thr_archived")],
            accountID: Self.account
        )
    }
}

@Suite @MainActor
struct LabelsTests {
    /// Fails if a label is modelled as a folder selection. It cannot be: a label
    /// spans every folder at once, so `ConversationFolder` has nowhere to put it
    /// and the sidebar item has to carry the label id itself.
    @Test("The sidebar's label item maps onto the label listing, not onto a folder")
    func sidebarItemRoundTrips() async throws {
        let harness = try await LabelHarness.make()
        try await harness.seed()
        await harness.model.reloadLabels()

        harness.model.sidebarItem = .label("lbl_1")
        #expect(harness.model.selectedLabelID == "lbl_1")
        #expect(harness.model.sidebarItem == .label("lbl_1"))
        #expect(harness.model.scopeTitle == "Billing")

        harness.model.sidebarItem = .folder(.init(mailboxID: nil, folder: .inbox))
        #expect(harness.model.selectedLabelID == nil)
        #expect(harness.model.sidebarItem == .folder(.init(mailboxID: nil, folder: .inbox)))
    }

    /// Fails if the folder presentation rule is applied to a label listing: the
    /// rule hides archived and trashed rows outside their own folders, which is
    /// most of what a label listing is for.
    @Test("A label lists across folders; the folder filter does not apply to it")
    func labelListingIsNotFolderFiltered() async throws {
        let harness = try await LabelHarness.make()
        try await harness.seed()
        await harness.model.reloadLabels()

        // The inbox does NOT show the archived thread…
        await harness.model.reloadConversations()
        #expect(harness.model.presentedConversations.map(\.id) == ["thr_inbox"])

        // …but the label it carries does.
        harness.model.showLabel("lbl_1")
        await harness.model.reloadTask?.value
        #expect(harness.model.presentedConversations.map(\.id) == ["thr_archived"])
        #expect(
            await harness.sync.labelRefreshCount == 1,
            "opening a label asks for a fresh sweep, like opening Drafts asks for drafts"
        )
    }

    /// Fails if the chips are read per row from the store, or if two rows with
    /// the same labels can show them in different orders.
    @Test("Row chips come from the index, in the sidebar's order")
    func chipDataIsIndexed() async throws {
        let harness = try await LabelHarness.make()
        try await harness.seed()
        try await harness.store.replaceAssignments(
            labelID: "lbl_2",
            messages: [LabelRowKey(messageID: "m2", threadID: "thr_archived")],
            accountID: LabelHarness.account
        )
        await harness.model.reloadLabels()
        await harness.model.reloadLabelIndex()

        // The sidebar orders by name (Billing, Later), which is what the chips
        // must follow whatever order the join table came back in.
        #expect(harness.model.labels(forThread: "thr_archived").map(\.name) == ["Billing", "Later"])
        #expect(harness.model.labels(forThread: "thr_inbox").isEmpty)
        #expect(harness.model.threadHasLabel("lbl_1", threadID: "thr_archived"))
        #expect(!harness.model.threadHasLabel("lbl_1", threadID: "thr_inbox"))
    }

    /// Fails if the chips are colour-only: VoiceOver hears the row's combined
    /// summary and nothing else, so the label names have to be in it.
    @Test("A row's accessibility summary names its labels")
    func accessibilityCarriesLabels() async throws {
        let row = MailFixtures.conversation(MailFixtures.message(id: "m1"))
        let summary = ConversationRow.accessibilitySummary(
            for: row,
            labels: [LabelHarness.label("lbl_1", "Billing")]
        )
        #expect(summary.contains("labelled Billing"))
        #expect(
            LabelChipRow.accessibilityPhrase(for: []) == nil,
            "an unlabelled row must not announce an empty label list"
        )
    }

    /// Fails if the chip appears only after the round trip: the whole point of
    /// the optimistic path is that triage feels instant.
    @Test("Assigning a label from the menu updates the chips, and the request is made")
    func assignmentIsOptimisticAndSent() async throws {
        let harness = try await LabelHarness.make()
        try await harness.seed()
        await harness.model.reloadLabels()
        await harness.model.reloadLabelIndex()

        await harness.model.setLabel("lbl_2", onThread: "thr_inbox", assigned: true)
        #expect(harness.model.labels(forThread: "thr_inbox").map(\.id) == ["lbl_2"])
        let writes = await harness.api.labelWrites
        #expect(writes.count == 1)
        #expect(writes.first?.labelID == "lbl_2")
        #expect(writes.first?.assigned == true)
        #expect(writes.first?.isConversation == true, "a list row's menu labels the whole thread")
        #expect(harness.model.actionError == nil)
    }

    /// Fails if a rejection leaves the chip on screen: the next sweep is up to
    /// two minutes away, and until then the row would claim a label the server
    /// refused.
    @Test("A refused assignment takes the chip back and surfaces the error")
    func rejectionRevertsTheChip() async throws {
        let harness = try await LabelHarness.make()
        try await harness.seed()
        await harness.model.reloadLabels()
        await harness.model.reloadLabelIndex()
        await harness.api.setLabelWriteError(.server(code: "http_403", message: "no"))

        await harness.model.setLabel("lbl_2", onThread: "thr_inbox", assigned: true)
        #expect(harness.model.labels(forThread: "thr_inbox").isEmpty)
        #expect(harness.model.actionError != nil)
    }

    /// Fails if a deleted label leaves the user inside a listing that can never
    /// be filled again.
    @Test("A label deleted in the workspace drops the user out of its listing")
    func deletedLabelLeavesItsListing() async throws {
        let harness = try await LabelHarness.make()
        try await harness.seed()
        await harness.model.reloadLabels()
        harness.model.showLabel("lbl_1")
        await harness.model.reloadTask?.value

        try await harness.store.replaceLabels(
            [LabelHarness.label("lbl_2", "Later")], accountID: LabelHarness.account
        )
        await harness.model.applyLabelsChanged()
        #expect(harness.model.selectedLabelID == nil)
    }

    // MARK: - Precomputed index (A3)

    /// Fails if the sidebar badge is derived by walking the index. It is asked
    /// for once per label per render pass, and the walk was O(threads × labels)
    /// IN THE VIEW BODY.
    @Test("Per-label thread counts are precomputed with the index, in one pass")
    func badgeCountsArePrecomputed() async throws {
        let harness = try await LabelHarness.make()
        try await harness.seed()
        try await harness.store.replaceAssignments(
            labelID: "lbl_2",
            messages: [
                LabelRowKey(messageID: "m1", threadID: "thr_inbox"),
                LabelRowKey(messageID: "m2", threadID: "thr_archived"),
            ],
            accountID: LabelHarness.account
        )
        await harness.model.reloadLabels()
        await harness.model.reloadLabelIndex()

        #expect(harness.model.labelThreadCounts == ["lbl_1": 1, "lbl_2": 2])
        #expect(harness.model.threadCount(forLabel: "lbl_1") == 1)
        #expect(harness.model.threadCount(forLabel: "lbl_2") == 2)
        // A label the workspace has but nobody has used reads zero, not nil.
        try await harness.store.replaceLabels(
            [
                LabelHarness.label("lbl_1", "Billing"),
                LabelHarness.label("lbl_2", "Later"),
                LabelHarness.label("lbl_3", "Waiting"),
            ],
            accountID: LabelHarness.account
        )
        await harness.model.reloadLabels()
        #expect(harness.model.threadCount(forLabel: "lbl_3") == 0)
    }

    /// Fails if the badge is a frame behind the chip. Both read the same index,
    /// so an optimistic toggle that rebuilt one and not the other would leave the
    /// sidebar contradicting the row the user just changed.
    @Test("An optimistic toggle moves the badge with the chip")
    func badgeFollowsAnOptimisticToggle() async throws {
        let harness = try await LabelHarness.make()
        try await harness.seed()
        await harness.model.reloadLabels()
        await harness.model.reloadLabelIndex()
        #expect(harness.model.threadCount(forLabel: "lbl_1") == 1)

        await harness.model.setLabel("lbl_1", onThread: "thr_inbox", assigned: true)
        #expect(harness.model.threadCount(forLabel: "lbl_1") == 2, "the added thread is counted")

        await harness.model.setLabel("lbl_1", onThread: "thr_inbox", assigned: false)
        #expect(harness.model.threadCount(forLabel: "lbl_1") == 1, "and uncounted again")
        #expect(harness.model.labels(forThread: "thr_inbox").isEmpty)
    }

    /// Fails if a label write rebuilds the index twice. `reloadConversations`
    /// rebuilds it itself (before it publishes the rows, so the chips are never a
    /// frame behind), so calling both was two whole-account index reads and a
    /// redundant store round trip per toggle.
    @Test("A label write rebuilds the index exactly once, inside a listing or out")
    func labelWriteReloadsTheIndexOnce() async throws {
        let harness = try await LabelHarness.make()
        try await harness.seed()
        await harness.model.reloadLabels()

        // Outside a listing: the index alone moved, so only the index reloads.
        var indexBaseline = harness.model.labelIndexReloadCount
        var rowBaseline = harness.model.conversationReloadCount
        await harness.model.setLabel("lbl_2", onThread: "thr_inbox", assigned: true)
        #expect(harness.model.labelIndexReloadCount == indexBaseline + 1)
        #expect(
            harness.model.conversationReloadCount == rowBaseline,
            "a folder listing is not re-read for a label the rows do not order by"
        )

        // Inside one: the rows ARE the membership, so the listing reloads — and
        // that reload is the index rebuild, not an extra one on top of it.
        harness.model.showLabel("lbl_1")
        await harness.model.reloadTask?.value
        indexBaseline = harness.model.labelIndexReloadCount
        rowBaseline = harness.model.conversationReloadCount
        await harness.model.setLabel("lbl_1", onThread: "thr_inbox", assigned: true)
        #expect(harness.model.conversationReloadCount == rowBaseline + 1)
        #expect(
            harness.model.labelIndexReloadCount == indexBaseline + 1,
            "the listing reload IS the index rebuild; a second one is wasted work"
        )
        #expect(
            harness.model.presentedConversations.map(\.id).sorted() == ["thr_archived", "thr_inbox"],
            "and the thread that just gained the label appears in it"
        )
    }

    // MARK: - Sweep cadence signal (A3)

    /// Fails if the engine is left sweeping at its fast cadence for a surface
    /// nobody can see. The sweep is one request PER LABEL; the signal is what
    /// buys the idle interval back.
    @Test("The label surface signal follows the labels, the listing and the app")
    func labelSurfaceSignalFollowsTheUI() async throws {
        let harness = try await LabelHarness.make()

        // No labels cached yet: nothing on screen is showing any.
        await harness.model.reloadLabels()
        #expect(await harness.sync.labelSurfaceVisibility.isEmpty, "false was already the default")

        // The workspace has labels and the app is frontmost — the sidebar is
        // drawing a badge per label and the list a chip per row.
        try await harness.seed()
        await harness.model.reloadLabels()
        #expect(await harness.sync.labelSurfaceVisibility == [true])

        // Backgrounded: same labels, nobody looking.
        await harness.model.setActive(false)
        #expect(await harness.sync.labelSurfaceVisibility == [true, false])

        // …but a label LISTING open outranks that: the rows on screen ARE the
        // membership, so it stays visible even while the app is not frontmost.
        harness.model.showLabel("lbl_1")
        await harness.model.reloadTask?.value
        #expect(await harness.sync.labelSurfaceVisibility == [true, false, true])

        // Leaving the listing while still backgrounded turns it off again.
        harness.model.showLabel(nil)
        await harness.model.reloadTask?.value
        #expect(await harness.sync.labelSurfaceVisibility == [true, false, true, false])

        // And a signal that did not change is never re-sent — this is one actor
        // hop per recomputation, from four call sites.
        await harness.model.setActive(false)
        #expect(await harness.sync.labelSurfaceVisibility.count == 4)
    }

    // MARK: - Membership from rows (upstream 1.4.2)

    /// The two routes the VIEW fetches directly — the single-message route and
    /// the thread route — embed labels too, and nothing else stores their
    /// summaries, so this is the only path that can carry them into the cache.
    /// Fails if the chips the reading pane is drawing are left a reconciliation
    /// behind the answer the app just received, and fails the other way if a
    /// pre-1.4.2 answer (no `labels` key) is allowed to clear them.
    @Test("A view-fetched summary's embedded labels reach the chips, and a silent one does not")
    func viewFetchedLabelsReachTheChips() async throws {
        let harness = try await LabelHarness.make()
        try await harness.seed()
        await harness.model.reloadLabels()
        await harness.model.reloadLabelIndex()
        #expect(harness.model.labelIDsByThread["thr_inbox"] == nil, "the inbox thread starts unlabelled")

        // A detail/thread answer from a 1.4.2 server: the message states its set.
        await harness.model.storeEmbeddedLabels(of: [
            MailFixtures.message(
                id: "m1", threadID: "thr_inbox",
                labels: [LabelHarness.label("lbl_2", "Later", color: .amber)]
            )
        ])
        #expect(
            harness.model.labelIDsByThread["thr_inbox"] == ["lbl_2"],
            "the freshest statement the app has must redraw the chips at once"
        )

        // The same answer from an older server says nothing at all.
        await harness.model.storeEmbeddedLabels(of: [
            MailFixtures.message(id: "m1", threadID: "thr_inbox")
        ])
        #expect(
            harness.model.labelIDsByThread["thr_inbox"] == ["lbl_2"],
            "an absent labels key is not 'no labels' and must not clear the chips"
        )
    }

    /// Drives the PUBLIC message-load entry point (`selectedMessageID`, which
    /// runs `loadDetail` — MailViewModel.swift:~1650) with a fake `message(id:)`
    /// answer that embeds labels, instead of calling `storeEmbeddedLabels`
    /// directly. Fails if the two production call sites (`loadThread` /
    /// `loadDetail`) that are the only things exercising this path in the real
    /// app were ever deleted or stopped reaching the store — the direct-call
    /// unit test above would stay green even then.
    ///
    /// Also fails if reading a message falls back to the per-label sweep route
    /// instead of trusting the embedded set: a real 1.4.2 answer never needs it.
    @Test("Opening a message with embedded labels updates the chips index, with no per-label sweep")
    func messageLoadUpdatesChipsFromEmbeddedLabels() async throws {
        let harness = try await LabelHarness.make()
        try await harness.store.replaceLabels(
            [LabelHarness.label("lbl_1", "Billing"), LabelHarness.label("lbl_2", "Later")],
            accountID: LabelHarness.account
        )
        await harness.model.reloadLabels()
        #expect(harness.model.labelIDsByThread["t-m1"] == nil, "the thread starts unlabelled")

        let summary = MailFixtures.message(
            id: "m1", threadID: "t-m1",
            labels: [LabelHarness.label("lbl_2", "Later", color: .amber)]
        )
        await harness.api.setDetail(MailFixtures.detail(summary))

        harness.model.selectedMessageID = "m1"
        try await wait("the chips index to pick up the embedded labels") {
            harness.model.labelIDsByThread["t-m1"] == ["lbl_2"]
        }
        #expect(
            await harness.api.labelListRequests.isEmpty,
            "the embedded set is enough; nothing should fall back to the per-label sweep"
        )
    }

    /// Drives the PUBLIC thread-open entry point (`selectedThreadID`, which runs
    /// `loadThread` → the uncached-thread fallback that fetches
    /// `api.thread(messageID:)` — MailViewModel.swift:~1625) with a fake answer
    /// that embeds labels on both messages. Same rationale as the message-load
    /// test above: this exercises the production wiring, not the helper it
    /// calls, and asserts no per-label sweep request is made either.
    @Test("Opening a server-found thread with embedded labels updates the chips index, with no per-label sweep")
    func threadOpenUpdatesChipsFromEmbeddedLabels() async throws {
        let harness = try await LabelHarness.make()
        try await harness.store.replaceLabels(
            [LabelHarness.label("lbl_1", "Billing"), LabelHarness.label("lbl_2", "Later")],
            accountID: LabelHarness.account
        )
        await harness.model.reloadLabels()

        // A thread the local cache has never listed — only the server search
        // knows about it — which is the only way `loadThread` reaches the
        // `api.thread(messageID:)` fallback that embeds labels.
        let latest = MailFixtures.message(
            id: "m9", threadID: "t9", mailboxID: "mbA", subject: "Zulu remote",
            labels: [LabelHarness.label("lbl_1", "Billing")]
        )
        let older = MailFixtures.message(
            id: "m8", threadID: "t9", mailboxID: "mbA", subject: "Zulu remote",
            date: MailFixtures.epoch.addingTimeInterval(-60),
            labels: [LabelHarness.label("lbl_1", "Billing")]
        )
        await harness.api.setConversationPage(
            ConversationPage(
                conversations: [MailFixtures.conversation(latest, messageCount: 2)],
                nextCursor: nil,
                totalCount: nil
            )
        )
        await harness.api.setThread(
            [MailFixtures.detail(latest), MailFixtures.detail(older)], forMessage: "m9"
        )

        harness.model.selection = MailViewModel.FolderSelection(mailboxID: "mbA", folder: .inbox)
        harness.model.searchQuery = "zulu"
        harness.model.submitSearch()
        await harness.model.serverSearchTask?.value

        harness.model.selectedThreadID = "t9"
        try await wait("the chips index to pick up the embedded labels") {
            harness.model.labelIDsByThread["t9"] == ["lbl_1"]
        }
        #expect(
            await harness.api.labelListRequests.isEmpty,
            "the embedded set is enough; nothing should fall back to the per-label sweep"
        )
    }
}
