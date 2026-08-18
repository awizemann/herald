import Foundation
import Testing
@testable import HeraldKit

/// The delta-sync engine: bootstrap (checkpoint → full listing → catch-up),
/// steady state (mailbox reconciliation → journal → derived conversations), and
/// the two escape hatches (410 re-bootstrap, 404 legacy fallback).
///
/// Every test drives the real `SyncEngine` through the scripted fake and asserts
/// on the CALL LOG as well as the store: order is half the contract here.
@Suite("SyncEngine journal mode")
struct JournalSyncTests {
    private let account = SyncFixtures.account
    private static let inboxOnly = SyncScope(folders: [SyncFolder(message: .inbox, conversation: .inbox)])

    /// Runs exactly one pass and stops. Event-driven; nothing here sleeps.
    private func runOnePass(_ engine: SyncEngine) async {
        await runPasses(engine, count: 1)
    }

    /// Runs `count` passes back to back (each extra one asked for with
    /// `refreshNow()`), then stops. Event-driven; nothing here sleeps.
    private func runPasses(_ engine: SyncEngine, count: Int) async {
        var completed = 0
        for await event in engine.events {
            switch event {
            case .finished, .failed:
                completed += 1
                if completed == count { await engine.stop(); return }
                await engine.refreshNow()
            default: continue
            }
        }
    }

    private func makeEngine(_ api: FakeMailAPIClient, _ store: MailStore) -> SyncEngine {
        SyncEngine(api: api, store: store, scope: Self.inboxOnly)
    }

    /// Puts the account into steady state without running a bootstrap first, so
    /// the journal behaviour under test is not entangled with the listing.
    private func seedCheckpoint(_ store: MailStore, cursor: String = "chk_0") async throws {
        try await store.setSyncCheckpoint(
            SyncCheckpoint(changeCursor: cursor, bootstrappedAt: Date(timeIntervalSince1970: 1_000)),
            accountID: account
        )
    }

    // MARK: - Bootstrap

    /// Fails on an off-by-one in the message page-walk: stopping at page 1 (the
    /// pre-pagination behaviour) loses everything past the first 100 rows, and
    /// asking for a fourth page after `nextCursor` went nil re-lists forever.
    @Test("Bootstrap page-walks three message pages and stores every row")
    func bootstrapPageWalksEveryMessagePage() async throws {
        let api = FakeMailAPIClient()
        await api.setSupportsChanges(true)
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setMessagePages(
            [
                [SyncFixtures.message("m1", threadID: "t1")],
                [SyncFixtures.message("m2", threadID: "t2")],
                [SyncFixtures.message("m3", threadID: "t3")],
            ],
            folder: .inbox,
            mailboxID: "mbx_a"
        )

        let store = try MailStore.inMemory()
        let engine = makeEngine(api, store)
        await engine.start(accountID: account)
        await runOnePass(engine)

        let cursors = await api.messageCursors()
        #expect(cursors == [nil, "inbox-mbx_a-p1", "inbox-mbx_a-p2"], "three pages, each following the previous cursor")
        let cached = try await store.messages(accountID: account, mailboxID: "mbx_a", folder: .inbox)
        #expect(Set(cached.map(\.id)) == ["m1", "m2", "m3"], "a page-walk that stops early silently drops mail")

        let checkpoint = try await store.syncCheckpoint(accountID: account)
        #expect(checkpoint?.bootstrappedAt != nil, "a finished bootstrap must be recorded or every pass re-lists")
    }

    /// The checkpoint MUST be taken before the listing: taken afterwards, every
    /// change that lands while the (slow) listing runs is never replayed and the
    /// cache is silently stale until the next unrelated change. Fails on any
    /// ordering that lists first or skips the catch-up read.
    @Test("Bootstrap takes the checkpoint before listing and consumes changes after it")
    func bootstrapOrdersCheckpointFirst() async throws {
        let api = FakeMailAPIClient()
        await api.setSupportsChanges(true)
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setMessages([SyncFixtures.message("m1")], folder: .inbox)

        let store = try MailStore.inMemory()
        let engine = makeEngine(api, store)
        await engine.start(accountID: account)
        await runOnePass(engine)

        let calls = await api.calls
        let checkpointIndex = try #require(calls.firstIndex(of: .changes(cursor: nil)))
        let listIndex = try #require(calls.firstIndex { if case .listMessages = $0 { return true } else { return false } })
        let catchUpIndex = try #require(calls.firstIndex(of: .changes(cursor: "chk_0")))
        #expect(checkpointIndex < listIndex, "the checkpoint must be older than the listing it protects")
        #expect(listIndex < catchUpIndex, "changes since the checkpoint are applied after the listing")
    }

    // MARK: - Steady state

    /// Fails if an upsert change is not applied to the cache (the row keeps its
    /// stale read state forever, since nothing re-lists it in journal mode).
    @Test("An upsert change updates the cached row")
    func upsertChangeUpdatesTheRow() async throws {
        let api = FakeMailAPIClient()
        await api.setSupportsChanges(true)
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        let read = Date(timeIntervalSince1970: 5_000)
        await api.setChangePages([
            ChangePage(
                changes: [.upsert(SyncFixtures.message("m1", readAt: read))],
                nextCursor: "c1",
                hasMore: false
            )
        ])

        let store = try MailStore.inMemory()
        _ = try await store.upsertMessages([SyncFixtures.message("m1")], accountID: account)
        _ = try await store.upsertMailboxes([SyncFixtures.mailbox("mbx_a")], accountID: account)
        try await seedCheckpoint(store)

        let engine = makeEngine(api, store)
        await engine.start(accountID: account)
        await runOnePass(engine)

        #expect(try await store.message(id: "m1", accountID: account)?.readAt == read)
        #expect(try await store.syncCheckpoint(accountID: account)?.changeCursor == "c1")
    }

    /// Fails if a tombstone leaves the row (deleted mail reappears in the list) or
    /// leaves the body sidecar behind (a cache leak keyed to an id that is gone).
    @Test("A delete change removes the message and its cached body")
    func deleteChangeRemovesRowAndBody() async throws {
        let api = FakeMailAPIClient()
        await api.setSupportsChanges(true)
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setChangePages([
            ChangePage(
                changes: [.delete(messageID: "m1", mailboxID: "mbx_a")],
                nextCursor: "c1",
                hasMore: false
            )
        ])

        let store = try MailStore.inMemory()
        _ = try await store.upsertMessages([SyncFixtures.message("m1")], accountID: account)
        _ = try await store.storeBody(messageID: "m1", accountID: account, textBody: "body", html: nil)
        _ = try await store.upsertMailboxes([SyncFixtures.mailbox("mbx_a")], accountID: account)
        try await seedCheckpoint(store)

        let engine = makeEngine(api, store)
        await engine.start(accountID: account)
        await runOnePass(engine)

        #expect(try await store.message(id: "m1", accountID: account) == nil)
        #expect(try await store.cachedBody(messageID: "m1", accountID: account) == nil, "the body sidecar outlived its message")
    }

    /// Conversation rows are derived, so they must be re-listed — but only where
    /// something changed. Fails if the pass re-lists every mailbox's
    /// conversations (the full-listing cost the journal exists to avoid) or none
    /// at all (thread rows never reflect the change).
    @Test("Only the mailboxes a change batch touched get their conversations refreshed")
    func conversationsRefreshOnlyTouchedScopes() async throws {
        let api = FakeMailAPIClient()
        await api.setSupportsChanges(true)
        let mailboxes = [SyncFixtures.mailbox("mbx_a"), SyncFixtures.mailbox("mbx_b")]
        await api.setMailboxes(mailboxes)
        await api.setChangePages([
            ChangePage(
                changes: [.upsert(SyncFixtures.message("m1", mailboxID: "mbx_a"))],
                nextCursor: "c1",
                hasMore: false
            )
        ])

        let store = try MailStore.inMemory()
        _ = try await store.upsertMailboxes(mailboxes, accountID: account)
        try await seedCheckpoint(store)

        let engine = makeEngine(api, store)
        await engine.start(accountID: account)
        await runOnePass(engine)

        let scopes = await api.conversationScopes()
        #expect(scopes == ["mbx_a:inbox"], "expected only the touched mailbox, got \(scopes)")
    }

    /// The crash-safety property: a cursor persisted only at the END of the cycle
    /// means a failure on page 3 replays pages 1–2 next time (double work, and
    /// with tombstones in the batch, resurrected rows). Fails if the store still
    /// holds the pre-cycle cursor after the third page throws.
    @Test("The change cursor is persisted after EVERY applied page, not just at the end")
    func cursorPersistsAfterEachPage() async throws {
        let api = FakeMailAPIClient()
        await api.setSupportsChanges(true)
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setChangePages([
            ChangePage(changes: [.upsert(SyncFixtures.message("m1"))], nextCursor: "c1", hasMore: true),
            ChangePage(changes: [.upsert(SyncFixtures.message("m2"))], nextCursor: "c2", hasMore: true),
            ChangePage(changes: [.upsert(SyncFixtures.message("m3"))], nextCursor: "c3", hasMore: false),
        ])
        // Page three never arrives.
        await api.setChangeFailure(.transport(.init(URLError(.timedOut))), forCursor: "c2")

        let store = try MailStore.inMemory()
        _ = try await store.upsertMailboxes([SyncFixtures.mailbox("mbx_a")], accountID: account)
        try await seedCheckpoint(store)

        let engine = makeEngine(api, store)
        await engine.start(accountID: account)
        await runOnePass(engine)

        let checkpoint = try await store.syncCheckpoint(accountID: account)
        #expect(checkpoint?.changeCursor == "c2", "the two applied pages must have advanced the cursor")
        #expect(try await store.message(id: "m2", accountID: account) != nil)
        #expect(try await store.message(id: "m3", accountID: account) == nil, "the failed page must not have been applied")
    }

    /// Fails if a 410 is treated as a normal error: the account would keep
    /// sending a cursor the server refuses and never sync again.
    @Test("410 cursorExpired drops the checkpoint and re-bootstraps in the same pass")
    func expiredCursorRebootstraps() async throws {
        let api = FakeMailAPIClient()
        await api.setSupportsChanges(true)
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setMessages([SyncFixtures.message("m1")], folder: .inbox)
        await api.setChangeFailure(.cursorExpired, forCursor: "chk_0")

        let store = try MailStore.inMemory()
        _ = try await store.upsertMailboxes([SyncFixtures.mailbox("mbx_a")], accountID: account)
        try await seedCheckpoint(store)

        let engine = makeEngine(api, store)
        await engine.start(accountID: account)
        await runOnePass(engine)

        let calls = await api.calls
        // Steady-state read (rejected) → fresh checkpoint → full listing → catch-up.
        #expect(calls.filter { $0 == .changes(cursor: nil) }.count == 1, "a new checkpoint must be taken")
        let checkpointIndex = try #require(calls.firstIndex(of: .changes(cursor: nil)))
        let listIndex = try #require(calls.firstIndex { if case .listMessages = $0 { return true } else { return false } })
        #expect(checkpointIndex < listIndex, "the re-bootstrap must list AFTER its new checkpoint")
        #expect(try await store.message(id: "m1", accountID: account) != nil, "the re-bootstrap must repopulate the cache")
        #expect(try await store.syncCheckpoint(accountID: account)?.bootstrappedAt != nil)
    }

    // MARK: - Mailbox reconciliation

    /// Access can be revoked. The journal never mentions a mailbox we cannot read,
    /// so nothing else would ever remove its mail: fails if the cache keeps rows
    /// (and a sidebar entry) for a mailbox the server stopped returning.
    @Test("A mailbox that disappears from /mailboxes has its cache purged")
    func vanishedMailboxIsPurged() async throws {
        let api = FakeMailAPIClient()
        await api.setSupportsChanges(true)
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])

        let store = try MailStore.inMemory()
        _ = try await store.upsertMailboxes(
            [SyncFixtures.mailbox("mbx_a"), SyncFixtures.mailbox("mbx_b")],
            accountID: account
        )
        _ = try await store.upsertMessages(
            [SyncFixtures.message("m_b", mailboxID: "mbx_b")],
            accountID: account
        )
        try await seedCheckpoint(store)

        let engine = makeEngine(api, store)
        await engine.start(accountID: account)
        await runOnePass(engine)

        #expect(try await store.message(id: "m_b", accountID: account) == nil, "revoked mailbox mail must be purged")
        #expect(try await store.mailboxes(accountID: account).map(\.id) == ["mbx_a"])
    }

    /// A newly readable mailbox has no journal history the client is entitled to
    /// replay, so it needs a listing — and it must happen BEFORE the cursor moves
    /// past the entries that mention it. Fails if the new mailbox is only listed
    /// after (or instead of) the change consumption.
    @Test("A newly appearing mailbox is bootstrap-listed before changes are consumed")
    func newMailboxIsListedBeforeChanges() async throws {
        let api = FakeMailAPIClient()
        await api.setSupportsChanges(true)
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a"), SyncFixtures.mailbox("mbx_b")])
        await api.setMessages([SyncFixtures.message("m_b", mailboxID: "mbx_b")], folder: .inbox)

        let store = try MailStore.inMemory()
        _ = try await store.upsertMailboxes([SyncFixtures.mailbox("mbx_a")], accountID: account)
        try await seedCheckpoint(store)

        let engine = makeEngine(api, store)
        await engine.start(accountID: account)
        await runOnePass(engine)

        let calls = await api.calls
        let listIndex = try #require(
            calls.firstIndex { if case .listMessages(_, "mbx_b", _) = $0 { return true } else { return false } }
        )
        let changesIndex = try #require(calls.firstIndex(of: .changes(cursor: "chk_0")))
        #expect(listIndex < changesIndex, "the new mailbox must be listed before the journal advances past it")
        #expect(try await store.message(id: "m_b", accountID: account) != nil)
        #expect(
            !calls.contains { if case .listMessages(_, "mbx_a", _) = $0 { return true } else { return false } },
            "an already-known mailbox must NOT be re-listed — that is the cost the journal removes"
        )
    }

    // MARK: - Legacy fallback

    /// The owner's server is 1.1.2 today. Fails if a 404 on `/changes` aborts the
    /// pass (no sync at all) instead of falling back, or if the engine re-probes
    /// the missing route on every later pass.
    @Test("A server without /changes falls back to legacy listing and stops probing")
    func serverWithoutChangesUsesLegacy() async throws {
        let api = FakeMailAPIClient()
        await api.setSupportsChanges(false)
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setMessages([SyncFixtures.message("m1")], folder: .inbox)

        let store = try MailStore.inMemory()
        let engine = makeEngine(api, store)
        await engine.start(accountID: account)
        // Three passes on ONE engine: the probe must happen on the first only.
        await runPasses(engine, count: 3)
        #expect(try await store.message(id: "m1", accountID: account) != nil, "legacy listing must still populate the cache")

        let passes = await api.callCount { $0 == .listMailboxes }
        #expect(passes == 3)
        let probes = await api.callCount { $0 == .changes(cursor: nil) }
        #expect(probes == 1, "one probe per engine lifetime, not per pass — got \(probes)")
        #expect(try await store.syncCheckpoint(accountID: account) == nil, "legacy mode must not fabricate a checkpoint")
    }

    /// PR-A shipped pagination before the journal, so a server can paginate and
    /// still have no `/changes`. The old guard skipped tombstoning for any
    /// cap-sized response; with a `Link` header the listing IS complete, so
    /// tombstoning must resume. Fails if a stale row survives a paginated legacy
    /// walk (the guard is now too broad).
    @Test("Legacy mode page-walks a paginating server and tombstones fully")
    func legacyPaginationTombstones() async throws {
        let api = FakeMailAPIClient()
        await api.setSupportsChanges(false)
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setMessagePages(
            [
                [SyncFixtures.message("m1", threadID: "t1")],
                [SyncFixtures.message("m2", threadID: "t2")],
            ],
            folder: .inbox,
            mailboxID: "mbx_a"
        )

        let store = try MailStore.inMemory()
        _ = try await store.upsertMessages([SyncFixtures.message("m_old", threadID: "t_old")], accountID: account)

        let engine = makeEngine(api, store)
        await engine.start(accountID: account)
        await runOnePass(engine)

        let cursors = await api.messageCursors()
        #expect(cursors == [nil, "inbox-mbx_a-p1"], "legacy mode must follow the Link cursor too")
        #expect(try await store.message(id: "m2", accountID: account) != nil)
        #expect(
            try await store.message(id: "m_old", accountID: account) == nil,
            "a complete paginated listing must tombstone what the server no longer returns"
        )
    }

    // MARK: - Optimistic action vs journal echo

    /// The journal echoes back the state a local action just POSTed. If
    /// `upsertMessages` reported that echo as a change, the list would repaint —
    /// and any row the user is mid-triage on would flicker — for no new
    /// information. Fails the moment change detection is weakened to blind
    /// assignment. (A DIFFERING echo still reverts: that is a failed POST.)
    @Test("An echoed upsert identical to the optimistic local state is a no-op")
    func equalEchoedUpsertIsANoOp() async throws {
        let store = try MailStore.inMemory()
        _ = try await store.upsertMessages([SyncFixtures.message("m1")], accountID: account)
        _ = try await store.applyLocalAction(.read, messageID: "m1", accountID: account)
        let optimistic = try #require(try await store.message(id: "m1", accountID: account))

        // Exactly what the server journals back once the POST lands.
        let echoed = try await store.upsertMessages([optimistic], accountID: account)
        #expect(echoed.isEmpty, "an identical echo must not produce a ChangeSet, got \(echoed)")

        // And the server disagreeing (the POST failed) still comes through.
        let differing = try await store.upsertMessages(
            [SyncFixtures.message("m1", readAt: nil)],
            accountID: account
        )
        #expect(differing.updated == ["m1"], "a genuinely different echo must still update the row")
    }
}
