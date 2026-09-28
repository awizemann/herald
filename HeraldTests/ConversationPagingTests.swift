import Foundation
import HeraldKit
import Testing
@testable import Herald

/// A sync engine whose "server" holds `older` more threads past the cache:
/// each `loadOlderConversations` stores the next `pageSize` of them.
private actor PagingSync: MailSyncing {
    let store: MailStore
    var older: [MessageSummary]
    let pageSize: Int
    var failNext = false
    private(set) var loadCalls = 0

    init(store: MailStore, older: [MessageSummary], pageSize: Int) {
        self.store = store
        self.older = older
        self.pageSize = pageSize
    }

    func refreshNow() {}
    func refreshDraftsNow() {}
    func refreshLabelsNow() {}
    func setCadence(_ cadence: SyncCadence) {}
    func setLabelSurfaceVisible(_ visible: Bool) {}
    func setFailNext() { failNext = true }

    func loadOlderConversations(mailboxIDs: Set<String>?, folder: ConversationFolder) async throws -> Bool {
        loadCalls += 1
        if failNext {
            failNext = false
            throw MailAPIError.server(code: "INTERNAL", message: "boom")
        }
        let page = Array(older.prefix(pageSize))
        older.removeFirst(page.count)
        try await store.upsertMessages(page, accountID: "acct")
        try await store.upsertConversations(
            page.map { MailFixtures.conversation($0) }, accountID: "acct", mailboxID: "mbA", folder: .inbox
        )
        return !older.isEmpty
    }
}

@MainActor
@Suite("Conversation list paging")
struct ConversationPagingTests {
    /// Thread `t<i>` is newer the smaller `i` is, so `t0…t99` is the first page.
    private static func message(_ index: Int) -> MessageSummary {
        MailFixtures.message(
            id: "m\(index)", threadID: "t\(index)", mailboxID: "mbA", subject: "Thread \(index)",
            date: MailFixtures.epoch.addingTimeInterval(TimeInterval(100_000 - index) * 60)
        )
    }

    private static func mailbox(_ id: String) -> Mailbox {
        Mailbox(
            id: id, address: "\(id)@example.com", addresses: [], displayName: id, isActive: true,
            accessLevel: .manager, createdAt: MailFixtures.epoch, updatedAt: MailFixtures.epoch
        )
    }

    /// `cached` threads in the store, `older` more behind the fake server.
    private func make(cached: Int, older: Int = 0) async throws -> (MailStore, PagingSync, MailViewModel) {
        let store = try MailStore.inMemory()
        try await store.upsertMailboxes([Self.mailbox("mbA")], accountID: "acct")
        let rows = (0..<cached).map(Self.message)
        try await store.upsertMessages(rows, accountID: "acct")
        try await store.upsertConversations(
            rows.map { MailFixtures.conversation($0) }, accountID: "acct", mailboxID: "mbA", folder: .inbox
        )
        let sync = PagingSync(store: store, older: (cached..<(cached + older)).map(Self.message), pageSize: 50)
        let api = FakeMailAPIClient()
        let (stream, _) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .unbounded)
        let model = MailViewModel(
            accountID: "acct", accountLabel: "Test", api: api, store: store,
            actions: MailActionService(api: api, store: store), sync: sync, events: stream,
            markReadDelay: .seconds(3_600)
        )
        model.showListing(mailboxID: "mbA", folder: .inbox)
        await model.start()
        return (store, sync, model)
    }

    /// Fails if the list is still capped at one page, if a page is skipped or
    /// repeated, or if the order breaks at the page boundary.
    @Test("Scrolling to the end shows the next cached page, in order, without duplicates")
    func secondPageFromCache() async throws {
        let (_, sync, model) = try await make(cached: 250)
        #expect(model.allConversations.count == 100)
        #expect(model.canLoadMoreConversations)

        await model.loadMoreConversations()
        #expect(model.allConversations.map(\.id) == (0..<200).map { "t\($0)" })
        await model.loadMoreConversations()
        #expect(model.allConversations.map(\.id) == (0..<250).map { "t\($0)" })
        #expect(await sync.loadCalls == 0, "the cache still had rows; nothing to ask the server")
    }

    /// Fails if a background reload (what every sync tick does) re-reads with
    /// the default limit and snaps the paged list back to 100 rows.
    @Test("A sync reload keeps every page already loaded")
    func syncReloadDoesNotTruncate() async throws {
        let (store, _, model) = try await make(cached: 250)
        await model.loadMoreConversations()
        #expect(model.allConversations.count == 200)

        // New mail lands on top, as a sync pass would store it.
        let fresh = MailFixtures.message(
            id: "m_new", threadID: "t_new", mailboxID: "mbA", subject: "New",
            date: MailFixtures.epoch.addingTimeInterval(TimeInterval(200_000) * 60)
        )
        try await store.upsertMessages([fresh], accountID: "acct")
        try await store.upsertConversations(
            [MailFixtures.conversation(fresh)], accountID: "acct", mailboxID: "mbA", folder: .inbox
        )
        await model.reloadConversations()
        #expect(model.allConversations.count == 200)
        #expect(model.allConversations.first?.id == "t_new")
        #expect(Set(model.allConversations.map(\.id)).count == 200, "no duplicates across the reload")
    }

    /// Fails if paging never reaches the server past the cache, if it keeps
    /// asking after the server's last page, or if a failure ends paging for good.
    @Test("Past the cache it pages the server, retries after a failure, and stops at the end")
    func serverPagesThenStops() async throws {
        let (_, sync, model) = try await make(cached: 100, older: 80)
        #expect(model.allConversations.count == 100)
        #expect(model.cacheMayHaveMoreConversations, "a full page cannot prove the cache is exhausted")

        await sync.setFailNext()
        // Cache read first (it finds nothing new), then — next scroll — the server.
        await model.loadMoreConversations()
        #expect(model.allConversations.count == 100)
        #expect(!model.cacheMayHaveMoreConversations)
        #expect(model.canLoadMoreConversations, "the server may still hold older threads")

        await model.loadMoreConversations()
        #expect(await sync.loadCalls == 1)
        #expect(model.allConversations.count == 100)
        #expect(model.canLoadMoreConversations, "a failure must leave the retry open")

        await model.loadMoreConversations()
        #expect(model.allConversations.count == 150)
        await model.loadMoreConversations()
        #expect(model.allConversations.map(\.id) == (0..<180).map { "t\($0)" })
        #expect(!model.canLoadMoreConversations, "the server said that was the last page")

        let calls = await sync.loadCalls
        await model.loadMoreConversations()
        #expect(await sync.loadCalls == calls, "no request after the end")
        #expect(!model.isLoadingMoreConversations)
    }

    /// Fails if a new listing inherits the previous one's page count (a slow
    /// first read everywhere) or its exhausted flag (never pages again).
    @Test("Navigating resets paging")
    func navigationResets() async throws {
        let (_, _, model) = try await make(cached: 100, older: 10)
        await model.loadMoreConversations()
        await model.loadMoreConversations()
        #expect(!model.canLoadMoreConversations)
        model.showListing(mailboxID: "mbA", folder: .archived)
        model.showListing(mailboxID: "mbA", folder: .inbox)
        #expect(model.conversationListLimit == MailViewModel.conversationPageSize)
        #expect(model.serverMayHaveMoreConversations)
    }
}
