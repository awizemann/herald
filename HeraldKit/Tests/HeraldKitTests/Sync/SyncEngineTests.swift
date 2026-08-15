import Foundation
import Testing
@testable import HeraldKit

@Suite("SyncEngine loop")
struct SyncEngineTests {
    private let account = SyncFixtures.account
    private static let inboxOnly = SyncScope(folders: [SyncFolder(message: .inbox, conversation: .inbox)])

    /// Collects events until `passes` passes have ended (`.finished` or
    /// `.failed`). Event-driven on purpose: no test here sleeps.
    private func awaitPasses(_ engine: SyncEngine, count: Int) async -> [EventKind] {
        var kinds: [EventKind] = []
        var completed = 0
        for await event in engine.events {
            kinds.append(EventKind(event))
            if case .began = event { continue }
            if case .changed = event { continue }
            completed += 1
            if completed == count { break }
        }
        return kinds
    }

    enum EventKind: Sendable, Hashable {
        case began, changed, finished, failed

        init(_ event: SyncEvent) {
            switch event {
            case .began: self = .began
            case .changed: self = .changed
            case .finished: self = .finished
            case .failed: self = .failed
            }
        }
    }

    /// Fails on an off-by-one in the page-walk (stopping at page 1, or asking
    /// for a fourth page after `nextCursor` went nil).
    @Test("Conversation page-walk follows nextCursor across three pages and stops")
    func pageWalkFollowsCursor() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setConversationPages([
            ConversationPage(conversations: [SyncFixtures.conversation(threadID: "t1")], nextCursor: "c1", totalCount: nil),
            ConversationPage(conversations: [SyncFixtures.conversation(threadID: "t2")], nextCursor: "c2", totalCount: nil),
            ConversationPage(conversations: [SyncFixtures.conversation(threadID: "t3")], nextCursor: nil, totalCount: nil),
        ])

        let store = try MailStore.inMemory()
        let engine = SyncEngine(api: api, store: store, scope: Self.inboxOnly)
        await engine.start(accountID: account)
        _ = await awaitPasses(engine, count: 1)
        await engine.stop()

        let cursors = await api.conversationCursors()
        #expect(cursors == [nil, "c1", "c2"], "Exactly three pages, each using the previous nextCursor")
        let cached = try await store.conversations(accountID: account, mailboxID: "mbx_a", folder: .inbox)
        #expect(Set(cached.map(\.id)) == ["t1", "t2", "t3"])
    }

    /// Fails if the page cap is missing (a server that always returns a cursor
    /// would spin forever) or if capping still tombstones the unseen pages.
    @Test("The page-walk stops at the cap and then refuses to tombstone")
    func pageWalkIsCapped() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        // Every page hands back a cursor: unbounded without the cap.
        await api.setConversationPages([
            ConversationPage(conversations: [SyncFixtures.conversation(threadID: "t1")], nextCursor: "c1", totalCount: nil),
            ConversationPage(conversations: [SyncFixtures.conversation(threadID: "t2")], nextCursor: "c1", totalCount: nil),
        ])

        let store = try MailStore.inMemory()
        let engine = SyncEngine(api: api, store: store, scope: Self.inboxOnly, maxConversationPages: 2)
        await engine.start(accountID: account)
        _ = await awaitPasses(engine, count: 1)
        await engine.stop()

        let pageCalls = await api.conversationCursors()
        #expect(pageCalls.count == 2, "Cap must bound the walk")
        let cached = try await store.conversations(accountID: account, mailboxID: "mbx_a", folder: .inbox)
        #expect(Set(cached.map(\.id)) == ["t1", "t2"], "A capped walk must not delete rows it never saw")
    }

    /// Fails if `refreshNow()` during an in-flight pass either spawns a second
    /// concurrent pass (three total) or is dropped entirely (one total).
    @Test("refreshNow during a pass coalesces into exactly one extra pass")
    func refreshNowCoalesces() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.armGate()

        let store = try MailStore.inMemory()
        let engine = SyncEngine(api: api, store: store, scope: Self.inboxOnly)

        var iterator = engine.events.makeAsyncIterator()
        await engine.start(accountID: account)

        // `.began` proves pass 1 started; it is emitted before the first request,
        // and the gate holds that request open.
        let first = await iterator.next()
        #expect(EventKind(first!) == .began)

        await engine.refreshNow()
        await api.openGate()

        _ = await awaitPasses(engine, count: 2)
        await engine.stop()

        let passes = await api.callCount { $0 == .listMailboxes }
        #expect(passes == 2, "One initial pass plus one coalesced refresh — never three")
    }

    /// Fails if an expired token leaves the loop running: the engine must stop
    /// so the UI can prompt for re-auth instead of hammering a 401.
    @Test("unauthorized stops the loop and makes no further calls")
    func unauthorizedStopsLoop() async throws {
        let api = FakeMailAPIClient()
        await api.setListFailure(.unauthorized)

        let store = try MailStore.inMemory()
        let engine = SyncEngine(api: api, store: store, scope: Self.inboxOnly)
        await engine.start(accountID: account)

        let kinds = await awaitPasses(engine, count: 1)
        #expect(kinds.last == .failed)

        // A refresh after the stop must be a no-op.
        await engine.refreshNow()
        let calls = await api.callCount { $0 == .listMailboxes }
        #expect(calls == 1, "The loop kept polling after a 401")
    }

    /// Fails if `.changed` is emitted on an unchanged poll (which would
    /// invalidate the whole list every 15 seconds).
    @Test("A second identical pass emits no .changed event")
    func unchangedPassIsSilent() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setMessages([SyncFixtures.message("m1")], folder: .inbox)
        await api.setConversationPages([
            ConversationPage(conversations: [SyncFixtures.conversation(threadID: "thr_1")], nextCursor: nil, totalCount: nil)
        ])

        let store = try MailStore.inMemory()
        let engine = SyncEngine(api: api, store: store, scope: Self.inboxOnly)
        var iterator = engine.events.makeAsyncIterator()
        await engine.start(accountID: account)

        var firstPass: [EventKind] = []
        while let event = await iterator.next() {
            let kind = EventKind(event)
            firstPass.append(kind)
            if kind == .finished { break }
        }
        #expect(firstPass.contains(.changed), "The first pass populates the cache")

        await engine.refreshNow()
        var secondPass: [EventKind] = []
        while let event = await iterator.next() {
            let kind = EventKind(event)
            secondPass.append(kind)
            if kind == .finished { break }
        }
        await engine.stop()

        #expect(secondPass == [.began, .finished], "Unchanged data must not publish a ChangeSet")
    }
}

@Suite("MailActionService")
struct MailActionServiceTests {
    private let account = SyncFixtures.account

    /// Fails if the service does not revert on a rejected action — the state the
    /// user sees would permanently disagree with the server.
    @Test("A rejected message action is reverted and the error rethrown")
    func rejectedActionReverts() async throws {
        let api = FakeMailAPIClient()
        await api.setActionFailure(.server(code: "CONFLICT", message: "nope"))
        let store = try MailStore.inMemory()
        _ = try await store.upsertMessages([SyncFixtures.message("m1")], accountID: account)

        let service = MailActionService(api: api, store: store)
        await #expect(throws: MailAPIError.self) {
            try await service.perform(.read, on: "m1", accountID: account)
        }
        #expect(try await store.message(id: "m1")?.readAt == nil, "Revert must undo the optimistic read")
        let attempted = await api.callCount { $0 == .performMessage(.read, "m1") }
        #expect(attempted == 1)
    }

    /// Fails if a successful action rolls the cache back anyway.
    @Test("A successful conversation action keeps the local change")
    func successfulConversationActionSticks() async throws {
        let api = FakeMailAPIClient()
        let store = try MailStore.inMemory()
        _ = try await store.upsertMessages(
            [SyncFixtures.message("m1"), SyncFixtures.message("m2")],
            accountID: account
        )

        let service = MailActionService(api: api, store: store)
        try await service.perform(.read, onConversation: "thr_1", in: .inbox, accountID: account)

        let messages = try await store.messages(accountID: account, threadID: "thr_1")
        #expect(messages.allSatisfy { $0.readAt != nil }, "Every message in the thread must be read")
    }
}
