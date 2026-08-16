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

    /// REAL-SERVER fact: `GET /messages` silently caps at 100 rows. Before this
    /// guard, a full-cap response was treated as the whole folder and every cached
    /// message the server didn't get to return was tombstoned — busy folders lost
    /// their older mail from the cache on every pass. Fails if a 100-row list
    /// tombstones, or if a 99-row list stops tombstoning (guard too broad).
    @Test("A message list at the server cap is treated as truncated and never tombstones")
    func fullCapMessageListDoesNotTombstone() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setConversationPages([ConversationPage(conversations: [], nextCursor: nil, totalCount: nil)])
        let store = try MailStore.inMemory()
        // An older message that is in the cache but beyond what the server returns.
        _ = try await store.upsertMessages([SyncFixtures.message("m_old", threadID: "t_old")], accountID: account)

        let cap = SyncEngine.serverMessageListCap
        await api.setMessages((0..<cap).map { SyncFixtures.message("m\($0)", threadID: "t\($0)") }, folder: .inbox)
        let engine = SyncEngine(api: api, store: store, scope: Self.inboxOnly)
        await engine.start(accountID: account)
        _ = await awaitPasses(engine, count: 1)
        await engine.stop()
        #expect(try await store.message(id: "m_old", accountID: account) != nil, "cap-sized list must not delete unreturned rows")

        // One under the cap is a complete listing again: tombstoning resumes.
        await api.setMessages((0..<(cap - 1)).map { SyncFixtures.message("m\($0)", threadID: "t\($0)") }, folder: .inbox)
        let engine2 = SyncEngine(api: api, store: store, scope: Self.inboxOnly)
        await engine2.start(accountID: account)
        _ = await awaitPasses(engine2, count: 1)
        await engine2.stop()
        #expect(try await store.message(id: "m_old", accountID: account) == nil, "a below-cap list is complete and must tombstone")
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

    /// URLSession reports a cancelled request as `MailAPIError.transport(URLError
    /// .cancelled)`, not `CancellationError` — so a sign-out or account switch used
    /// to surface in the UI as a sync FAILURE and push the loop into exponential
    /// backoff. Fails on any pass that treats a cancellation as a server error.
    @Test("A cancelled pass emits no .failed and does not arm the backoff")
    func cancelledPassIsNotAFailure() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setListFailure(.transport(.init(URLError(.cancelled))))

        let store = try MailStore.inMemory()
        let engine = SyncEngine(api: api, store: store, scope: Self.inboxOnly)
        var iterator = engine.events.makeAsyncIterator()
        await engine.start(accountID: account)

        // Pass 1 is the cancelled one; it must publish nothing but `.began`.
        var kinds: [EventKind] = []
        kinds.append(EventKind(await iterator.next()!))
        try await waitUntil("the cancelled pass to end") { await engine.isParkedOnCadenceWait }
        #expect(await engine.consecutiveFailureCount == 0, "A cancellation must not arm the backoff")

        // Pass 2 succeeds, so the stream has a terminator to assert against.
        await api.setListFailure(nil)
        await engine.refreshNow()
        while let event = await iterator.next() {
            let kind = EventKind(event)
            kinds.append(kind)
            if kind == .finished { break }
        }
        await engine.stop()

        #expect(!kinds.contains(.failed), "The cancelled pass reported a sync failure")
    }

    /// The timer/wake race: a cadence timer armed for a wait that `refreshNow()`
    /// already ended used to latch `wakeSignalled`, so the NEXT wait returned
    /// instantly — a free extra pass, and at speed a spin loop. Fails on any
    /// implementation whose timer signals without checking whose wait it belongs to.
    @Test("A stale cadence timer does not wake the loop")
    func staleTimerDoesNotWakeTheLoop() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])

        let store = try MailStore.inMemory()
        let engine = SyncEngine(api: api, store: store, scope: Self.inboxOnly)
        await engine.start(accountID: account)
        _ = await awaitPasses(engine, count: 1)
        try await waitUntil("the loop to park after pass 1") { await engine.isParkedOnCadenceWait }

        // A timer armed for a wait that has already ended.
        await engine.timerFired(generation: 0)
        #expect(await engine.isParkedOnCadenceWait, "A stale timer woke the loop")

        // The current wait's timer still works, so the guard is not "ignore everything".
        await engine.timerFired(generation: 1)
        #expect(await engine.isParkedOnCadenceWait == false)
        await engine.stop()
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
    /// Starred is a real server-side `ConversationFolder` with NO message folder
    /// behind it. Fails if the default scope stops walking it (the Starred
    /// sidebar folder then stays permanently empty), or if the engine tries to
    /// list `GET /messages?folder=starred`, which does not exist.
    @Test("The default scope walks starred conversations and asks for no starred messages")
    func defaultScopeWalksStarredConversations() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setConversationPages([
            ConversationPage(conversations: [], nextCursor: nil, totalCount: nil),
        ])

        let store = try MailStore.inMemory()
        let engine = SyncEngine(api: api, store: store, scope: .default)
        await engine.start(accountID: account)
        _ = await awaitPasses(engine, count: 1)
        await engine.stop()

        let calls = await api.calls
        let conversationFolders = calls.compactMap { call -> ConversationFolder? in
            guard case let .listConversations(folder, _, _) = call else { return nil }
            return folder
        }
        #expect(Set(conversationFolders) == [.inbox, .starred, .sent, .archived, .trash])

        let messageFolders = calls.compactMap { call -> MailFolder? in
            guard case let .listMessages(folder, _) = call else { return nil }
            return folder
        }
        #expect(
            Set(messageFolders) == [.inbox, .sent, .archived, .trash],
            "starred has no message folder; a message list for it would 400"
        )
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
        #expect(try await store.message(id: "m1", accountID: account)?.readAt == nil, "Revert must undo the optimistic read")
        let attempted = await api.callCount { $0 == .performMessage(.read, "m1") }
        #expect(attempted == 1)
    }

    /// The mirror of `rejectedActionReverts`, and the case no test could reach
    /// while the fake's `perform(onMessage:)` always threw: a server that ACCEPTS
    /// the action must leave the optimistic write in place, and must not fire the
    /// revert path.
    @Test("A successful message action sticks and does not revert")
    func successfulMessageActionSticks() async throws {
        let api = FakeMailAPIClient()
        let store = try MailStore.inMemory()
        _ = try await store.upsertMessages([SyncFixtures.message("m1")], accountID: account)

        let service = MailActionService(api: api, store: store)
        try await service.perform(.star, on: "m1", accountID: account)

        #expect(try await store.message(id: "m1", accountID: account)?.starredAt != nil, "The accepted star was rolled back")
        #expect(await api.callCount { $0 == .performMessage(.star, "m1") } == 1)
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

    /// REAL-SERVER regression (2026-08-15): the server's conversation-action `id`
    /// is a MESSAGE id — it resolves the mailbox for the access check from it.
    /// Sending the thread id yielded 403 MAILBOX_FORBIDDEN on star/archive.
    /// Fails if the service ever puts the thread id on the wire again.
    @Test("Conversation actions go to the server keyed by a message in the thread")
    func conversationActionSendsAMessageIDNotTheThreadID() async throws {
        let api = FakeMailAPIClient()
        let store = try MailStore.inMemory()
        _ = try await store.upsertMessages(
            [SyncFixtures.message("m1"), SyncFixtures.message("m2")],
            accountID: account
        )

        let service = MailActionService(api: api, store: store)
        try await service.perform(.star, onConversation: "thr_1", in: .inbox, accountID: account)

        let sent = await api.calls.compactMap { call -> String? in
            if case let .performConversation(_, id, _) = call { return id }
            return nil
        }
        #expect(sent.count == 1)
        #expect(["m1", "m2"].contains(sent.first ?? ""), "wire id must be a member message, got \(sent)")
        #expect(sent.first != "thr_1")
    }

}
