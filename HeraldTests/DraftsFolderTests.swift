import Foundation
import HeraldKit
import Testing
@testable import Herald

/// Records what the view-model asked the sync engine to do. The point of
/// interest is the DRAFTS refresh: it is deliberately not on `refreshNow`, so
/// "opening the folder asked for drafts, archiving a message did not" has to be
/// observable.
private actor FakeSync: MailSyncing {
    private(set) var refreshCount = 0
    private(set) var draftRefreshCount = 0
    private(set) var labelRefreshCount = 0
    /// Every value the view-model pushed for the label surface, in order.
    private(set) var labelSurfaceVisibility: [Bool] = []
    private(set) var cadences: [SyncCadence] = []

    func refreshNow() { refreshCount += 1 }
    func refreshDraftsNow() { draftRefreshCount += 1 }
    func refreshLabelsNow() { labelRefreshCount += 1 }
    func setCadence(_ cadence: SyncCadence) { cadences.append(cadence) }
    func setLabelSurfaceVisible(_ visible: Bool) { labelSurfaceVisibility.append(visible) }
}

/// A drafts-shaped view-model plus the handles the tests drive it with.
@MainActor
private struct DraftHarness {
    let store: MailStore
    let api: FakeMailAPIClient
    let sync: FakeSync
    let model: MailViewModel

    static let account = "acct"

    static func make() async throws -> DraftHarness {
        let store = try MailStore.inMemory()
        let api = FakeMailAPIClient()
        let sync = FakeSync()
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
        return DraftHarness(store: store, api: api, sync: sync, model: model)
    }

    static func draft(
        id: String,
        version: Int = 1,
        to: [String] = ["ada@example.net"],
        subject: String = "Quote",
        text: String = "Here it is.",
        updatedAt: Date = Date(timeIntervalSince1970: 3_000)
    ) -> Draft {
        Draft(
            id: id,
            version: version,
            updatedAt: updatedAt,
            attachments: [],
            content: DraftInput(
                mailboxID: "mbA",
                from: "support@example.com",
                to: to,
                subject: subject,
                text: text
            )
        )
    }

    func seed(_ drafts: [Draft]) async throws {
        try await store.reconcileDrafts(drafts, accountID: Self.account)
    }
}

@Suite @MainActor
struct DraftsFolderTests {
    /// Fails if the Drafts sidebar item is modelled as a folder selection. It
    /// cannot be one — there is no `drafts` conversation folder on the server —
    /// and mapping it onto a folder would list messages from a route
    /// (`GET /messages?folder=drafts`) that is permanently empty.
    @Test("Selecting Drafts shows the drafts list without disturbing the folder scope")
    func selectingDraftsIsNotAFolderChange() async throws {
        let harness = try await DraftHarness.make()
        try await harness.seed([DraftHarness.draft(id: "dft_1")])
        harness.model.selection = MailViewModel.FolderSelection(mailboxID: "mbA", folder: .archived)

        harness.model.sidebarItem = .drafts

        #expect(harness.model.isShowingDrafts)
        #expect(harness.model.sidebarItem == .drafts)
        // The conversation scope is untouched, so going back lands where the
        // user left rather than in the inbox.
        #expect(harness.model.selection.folder == .archived)
        #expect(harness.model.selection.mailboxID == "mbA")
        #expect(harness.model.scopeTitle == "Drafts")

        harness.model.sidebarItem = .folder(
            MailViewModel.FolderSelection(mailboxID: "mbA", folder: .archived)
        )
        #expect(!harness.model.isShowingDrafts)
        #expect(harness.model.scopeTitle == "Archived")
    }

    /// Fails if opening the folder does not ask for fresh drafts. The poll runs
    /// on a slow interval precisely because nobody is usually looking; this is
    /// the moment somebody is.
    @Test("Opening Drafts loads the cache and asks the engine for a fresh listing")
    func openingDraftsRefreshes() async throws {
        let harness = try await DraftHarness.make()
        try await harness.seed([DraftHarness.draft(id: "dft_1"), DraftHarness.draft(id: "dft_2", subject: "Second")])

        harness.model.showDrafts(true)
        try await wait("the drafts list loaded", until: { harness.model.drafts.count == 2 })

        #expect(harness.model.draftCount == 2)
        try await wait("the engine was asked for drafts", until: {
            await harness.sync.draftRefreshCount == 1
        })
        // Triage does NOT drag a whole-list drafts read behind it.
        #expect(await harness.sync.refreshCount == 0)
    }

    /// Fails if a composer's autosave only reaches the server: the Drafts folder
    /// would not show the message being typed until the next poll, up to a full
    /// interval later.
    @Test("A composer autosave shows up in the folder immediately")
    func autosaveWritesThrough() async throws {
        let harness = try await DraftHarness.make()
        harness.model.showDrafts(true)
        try await wait("the empty list settled", until: { harness.model.draftReloadCount > 0 })
        #expect(harness.model.drafts.isEmpty)

        await harness.model.applyDraftCacheEvent(.saved(DraftHarness.draft(id: "dft_new", subject: "In progress")))

        #expect(harness.model.drafts.map(\.id) == ["dft_new"])
        #expect(harness.model.drafts.first?.subject == "In progress")
        #expect(harness.model.draftCount == 1)
        // And it is fenced, so a poll that predates it cannot delete it.
        #expect(await harness.store.isDraftOpen(id: "dft_new", accountID: DraftHarness.account))
    }

    /// Fails if sending leaves the row behind — the user would see a draft of the
    /// message they just sent sitting in the folder.
    @Test("Sending or discarding removes the row, closing does not")
    func sendAndCloseAreDifferent() async throws {
        let harness = try await DraftHarness.make()
        try await harness.seed([DraftHarness.draft(id: "dft_1")])
        await harness.model.reloadDrafts()
        #expect(harness.model.drafts.count == 1)

        // Closing the window keeps the draft; it only hands the row back to the poll.
        await harness.model.applyDraftCacheEvent(.closed("dft_1"))
        #expect(harness.model.drafts.map(\.id) == ["dft_1"])
        #expect(await harness.store.isDraftOpen(id: "dft_1", accountID: DraftHarness.account) == false)

        await harness.model.applyDraftCacheEvent(.removed("dft_1"))
        #expect(harness.model.drafts.isEmpty)
        #expect(harness.model.draftCount == 0)
    }

    /// Fails if the delete waits for the server: mail triage must feel instant,
    /// and this is the same optimistic contract every other action has.
    @Test("Deleting a draft removes the row before the server answers")
    func deleteIsOptimistic() async throws {
        let harness = try await DraftHarness.make()
        try await harness.seed([DraftHarness.draft(id: "dft_1"), DraftHarness.draft(id: "dft_2", subject: "Keep")])
        await harness.model.reloadDrafts()

        await harness.model.deleteDraft("dft_1")

        #expect(harness.model.drafts.map(\.id) == ["dft_2"])
        #expect(harness.model.actionError == nil)
        #expect(await harness.api.deletedDraftIDs == ["dft_1"])
    }

    /// Fails if a refused delete is not reverted: the draft would be gone from
    /// the folder while still living on the server, and would silently reappear
    /// at the next poll — or never, if the fence were left behind.
    @Test("A refused delete puts the draft back, exactly as it was")
    func refusedDeleteReverts() async throws {
        let harness = try await DraftHarness.make()
        try await harness.seed([DraftHarness.draft(id: "dft_1", version: 3, subject: "Precious")])
        await harness.model.reloadDrafts()
        await harness.api.setDraftDeleteError(.server(code: "http_500", message: "nope"))

        await harness.model.deleteDraft("dft_1")

        #expect(harness.model.drafts.map(\.id) == ["dft_1"])
        #expect(harness.model.actionError != nil)
        let restored = try #require(try await harness.store.draft(id: "dft_1", accountID: DraftHarness.account))
        #expect(restored.version == 3, "the restored draft must carry its original version stamp")
        #expect(restored.content.subject == "Precious")
        // The restore is not a composer opening: a fence left behind here is a
        // row the poll could never tombstone again.
        #expect(await harness.store.isDraftOpen(id: "dft_1", accountID: DraftHarness.account) == false)
    }

    /// Fails if the composer is seeded from the network instead of the cache —
    /// opening a draft would cost a round trip and fail offline.
    @Test("Opening a draft builds its composer context from the cache alone")
    func openBuildsContextFromCache() async throws {
        let harness = try await DraftHarness.make()
        try await harness.seed([DraftHarness.draft(id: "dft_1", version: 6, subject: "Quote", text: "Body text")])
        await harness.model.reloadDrafts()
        harness.model.selectedDraftID = "dft_1"

        harness.model.openSelectedDraft()
        let request = try #require(harness.model.composeRequest)
        #expect(request.kind == .draft)
        #expect(request.draftID == "dft_1")

        let context = try #require(await harness.model.composeContext(for: request))
        let composed = context.makeDraft()
        #expect(composed.subject == "Quote")
        #expect(composed.body == "Body text")
        #expect(composed.draftInput.version == 6, "the cached version stamp is what the next PATCH needs")
        #expect(!composed.isDirty)
        // No `GET /drafts/{id}` was needed at all.
        #expect(await harness.api.fetchedDraftIDs.isEmpty)
    }

    /// Fails if a draft that vanished under the cursor leaves the composer
    /// opening on nothing — the window would show "no longer available".
    @Test("Opening a draft that is already gone reports it instead of opening a window")
    func openMissingDraft() async throws {
        let harness = try await DraftHarness.make()
        let request = ComposeRequest(kind: .draft, draftID: "dft_gone")

        #expect(await harness.model.composeContext(for: request) == nil)
        #expect(harness.model.actionError != nil)
    }

    /// Fails if a composer's draft events are routed to the SELECTED account
    /// instead of the one it was opened from. With two accounts signed in, the
    /// user can switch the window while a composer is up — and the draft belongs
    /// to the account whose `OutboxService` is saving it, not to whatever the
    /// window happens to be showing.
    @Test("A composer's draft is cached under the account it was opened from")
    func draftsFollowTheComposersAccount() async throws {
        let a = Account(origin: URL(string: "https://a.example.com")!, clientID: "cid", scopes: [])
        let b = Account(origin: URL(string: "https://b.example.com")!, clientID: "cid", scopes: [])
        let suite = "DraftsFolderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let environment = AppEnvironment(defaults: defaults)
        let store = try MailStore.inMemory()

        await environment.install(account: a, api: FakeMailAPIClient(), store: store)
        let composedFrom = try #require(environment.graphs[a.id]?.mail)
        // The window moves to B while the composer stays with A.
        await environment.install(account: b, api: FakeMailAPIClient(), store: store)
        #expect(environment.selectedAccountID == b.id)

        await composedFrom.applyDraftCacheEvent(.saved(DraftHarness.draft(id: "dft_1")))

        #expect(try await store.draftCount(accountID: a.id) == 1)
        #expect(try await store.draftCount(accountID: b.id) == 0, "the draft landed in the wrong account")
    }

    /// Fails if a row's spoken label drops what the row shows: on screen the
    /// state is two greyed lines, a date and a paperclip, none of which say
    /// anything out loud.
    @Test("A draft row's labels cover recipients, subject and attachments")
    func rowLabels() {
        let withRecipients = DraftSummary(
            id: "d1",
            mailboxID: "mbA",
            recipients: ["ada@example.net"],
            subject: "Quote",
            snippet: "Here it is.",
            updatedAt: Date(timeIntervalSince1970: 3_000),
            hasAttachments: true
        )
        #expect(MailViewModel.recipientsLabel(for: withRecipients) == "To: ada@example.net")
        #expect(MailViewModel.subjectLabel(for: withRecipients) == "Quote")
        let spoken = MailViewModel.accessibilitySummary(for: withRecipients)
        #expect(spoken.contains("ada@example.net"))
        #expect(spoken.contains("Quote"))
        #expect(spoken.contains("has attachments"))

        let empty = DraftSummary(
            id: "d2",
            mailboxID: nil,
            recipients: [],
            subject: "",
            snippet: "",
            updatedAt: Date(timeIntervalSince1970: 3_000),
            hasAttachments: false
        )
        // An empty draft must still read as something, not as a blank row.
        #expect(MailViewModel.recipientsLabel(for: empty) == "No recipients")
        #expect(MailViewModel.subjectLabel(for: empty) == "(No subject)")
    }
}
