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

    /// Like `runPasses`, but reports whether each pass ENDED in `.failed`.
    /// Used where the distinction between "reported a failure" and "quietly fell
    /// back to another mode" is the whole point of the test.
    @discardableResult
    private func runPassOutcomes(_ engine: SyncEngine, count: Int) async -> [Bool] {
        var outcomes: [Bool] = []
        for await event in engine.events {
            switch event {
            case .finished: outcomes.append(false)
            case .failed: outcomes.append(true)
            default: continue
            }
            if outcomes.count == count { await engine.stop(); return outcomes }
            await engine.refreshNow()
        }
        return outcomes
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
    /// assignment.
    ///
    /// The second half used to assert that a DIFFERING echo overwrites a PENDING
    /// row — which is the bug audit item 1 removed, not a contract: an older
    /// journal page must never win against an unconfirmed local action. What is
    /// genuinely required is that a differing upsert still lands on a row nobody
    /// is holding, and that is what it asserts now.
    @Test("An echoed upsert identical to the optimistic local state is a no-op")
    func equalEchoedUpsertIsANoOp() async throws {
        let store = try MailStore.inMemory()
        _ = try await store.upsertMessages([SyncFixtures.message("m1")], accountID: account)
        let undo = try await store.applyLocalAction(.read, messageID: "m1", accountID: account)
        let optimistic = try #require(try await store.message(id: "m1", accountID: account))

        // Exactly what the server journals back once the POST lands.
        let echoed = try await store.upsertMessages([optimistic], accountID: account)
        #expect(echoed.isEmpty, "an identical echo must not produce a ChangeSet, got \(echoed)")

        // Once the action settles the fence is gone, and a differing journal
        // upsert for that (now unheld) row updates it like any other.
        try await store.completeLocalAction(undo)
        let differing = try await store.upsertMessages(
            [SyncFixtures.message("m1", readAt: nil)],
            accountID: account
        )
        #expect(differing.updated == ["m1"], "a differing upsert on a non-pending row must still update it")
        #expect(try await store.message(id: "m1", accountID: account)?.readAt == nil)
    }

    // MARK: - Audit fixes (2026-08-18)

    /// A cursor persisted while the DERIVED conversation rows are still stale is
    /// a cache that never heals: the page that would have fixed them is now
    /// behind the cursor and is never read again. Refreshing only after the whole
    /// walk loses every earlier page's scopes the moment a later page throws.
    /// Fails on the end-of-walk refresh: pages 1–2 refreshed nothing.
    @Test("Touched conversation scopes are refreshed per page, before that page's cursor is stored")
    func conversationScopesRefreshBeforeTheCursorAdvances() async throws {
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

        let scopes = await api.conversationScopes()
        #expect(
            scopes == ["mbx_a:inbox", "mbx_a:inbox"],
            "each applied page must refresh its own scopes before its cursor lands, got \(scopes)"
        )
        #expect(try await store.syncCheckpoint(accountID: account)?.changeCursor == "c2")
    }

    /// A message that MOVES makes two listings stale, not one. Refreshing only
    /// the destination leaves the source list showing a thread that is no longer
    /// in it until something unrelated happens to touch that scope. Fails on the
    /// destination-only version: archived is refreshed, inbox is not.
    @Test("A journal upsert that moves a message refreshes the old scope as well as the new")
    func folderMoveRefreshesBothScopes() async throws {
        let api = FakeMailAPIClient()
        await api.setSupportsChanges(true)
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setChangePages([
            ChangePage(
                changes: [.upsert(SyncFixtures.message("m1", folder: .archived))],
                nextCursor: "c1",
                hasMore: false
            )
        ])

        let store = try MailStore.inMemory()
        _ = try await store.upsertMailboxes([SyncFixtures.mailbox("mbx_a")], accountID: account)
        _ = try await store.upsertMessages([SyncFixtures.message("m1", folder: .inbox)], accountID: account)
        try await seedCheckpoint(store)

        let engine = SyncEngine(
            api: api,
            store: store,
            scope: SyncScope(folders: [.inbox, .archived])
        )
        await engine.start(accountID: account)
        await runOnePass(engine)

        let scopes = Set(await api.conversationScopes())
        #expect(
            scopes == ["mbx_a:inbox", "mbx_a:archived"],
            "the listing the message moved OUT of must be refreshed too, got \(scopes)"
        )
    }

    /// Writing a new mailbox's row before its listing succeeds makes the mailbox
    /// "known" — and steady state only bootstrap-lists mailboxes it considers
    /// NEW. A listing that then throws leaves a mailbox no pass will ever list
    /// again, showing the user a permanently empty folder. Fails if the row
    /// survives the failed listing.
    @Test("A new mailbox whose listing fails is not persisted, and the next pass bootstraps it")
    func newMailboxRowWaitsForItsListing() async throws {
        let api = FakeMailAPIClient()
        await api.setSupportsChanges(true)
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a"), SyncFixtures.mailbox("mbx_b")])
        await api.setMessages([SyncFixtures.message("m_b", mailboxID: "mbx_b")], folder: .inbox)
        await api.setMessageListFailure(.transport(.init(URLError(.timedOut))), forMailbox: "mbx_b")

        let store = try MailStore.inMemory()
        _ = try await store.upsertMailboxes([SyncFixtures.mailbox("mbx_a")], accountID: account)
        try await seedCheckpoint(store)

        let engine = makeEngine(api, store)
        await engine.start(accountID: account)
        await runOnePass(engine)

        #expect(
            try await store.mailboxes(accountID: account).map(\.id) == ["mbx_a"],
            "a mailbox whose bootstrap listing failed must not be recorded as known"
        )

        // The next pass still treats it as new, so it gets its listing.
        await api.setMessageListFailure(nil, forMailbox: "mbx_b")
        let engine2 = makeEngine(api, store)
        await engine2.start(accountID: account)
        await runOnePass(engine2)

        #expect(try await store.mailboxes(accountID: account).map(\.id) == ["mbx_a", "mbx_b"])
        #expect(try await store.message(id: "m_b", accountID: account) != nil, "the retry must actually list it")
    }

    /// `stop()` only ASKS the loop to end; the pass is still parked on a request
    /// and keeps writing when it returns. Sign-out purges the cache immediately
    /// afterwards, so an un-awaited stop lets the OLD account's rows land behind
    /// the purge. Fails on any teardown that does not wait for the pass to unwind.
    @Test("stopAndWait outlives the in-flight pass, so a purge after it stays purged")
    func stopAndWaitFencesThePassAgainstAPurge() async throws {
        let api = FakeMailAPIClient()
        await api.setSupportsChanges(true)
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setMessages([SyncFixtures.message("m1")], folder: .inbox)
        await api.armGate()

        let store = try MailStore.inMemory()
        let engine = makeEngine(api, store)
        await engine.start(accountID: account)
        try await waitUntil("the pass to park mid-request") {
            await api.callCount { $0 == .listMailboxes } == 1
        }

        let stopper = Task { await engine.stopAndWait() }
        await api.openGate()
        await stopper.value

        let callsAtStop = await api.calls.count
        try await store.deleteAll(accountID: account)

        #expect(try await store.mailboxes(accountID: account).isEmpty, "the stopped pass wrote in behind the purge")
        #expect(try await store.message(id: "m1", accountID: account) == nil)
        #expect(try await store.syncCheckpoint(accountID: account) == nil)
        #expect(await api.calls.count == callsAtStop, "the pass was still issuing requests after stopAndWait returned")
    }

    /// A 404 means "no such route" only on the cursor-less probe. With a cursor
    /// in hand the account has already used `/changes` successfully, so a 404
    /// there is a transient server fault. Treating it as "no journal" drops the
    /// account into full re-listing every 15 seconds for the rest of the session.
    /// Fails on the un-scoped 404 check: the pass would succeed via legacy and
    /// re-list every mailbox.
    @Test("A 404 on a CURSORED /changes page is a pass failure, not a legacy fallback")
    func cursoredNotFoundDoesNotFlipToLegacy() async throws {
        let api = FakeMailAPIClient()
        await api.setSupportsChanges(true)
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setMessages([SyncFixtures.message("m1")], folder: .inbox)
        await api.setChangeFailure(.notFound, forCursor: "chk_0")

        let store = try MailStore.inMemory()
        _ = try await store.upsertMailboxes([SyncFixtures.mailbox("mbx_a")], accountID: account)
        try await seedCheckpoint(store)

        let engine = makeEngine(api, store)
        await engine.start(accountID: account)
        let outcomes = await runPassOutcomes(engine, count: 1)

        #expect(outcomes == [true], "a 404 on a cursored page must be reported as a failed pass")
        let calls = await api.calls
        #expect(
            !calls.contains(.changes(cursor: nil)),
            "the account must stay in journal mode; only the probe may re-checkpoint"
        )
        #expect(
            !calls.contains { if case .listMessages = $0 { return true } else { return false } },
            "a legacy fallback re-listed every mailbox"
        )
        #expect(try await store.syncCheckpoint(accountID: account)?.changeCursor == "chk_0", "the cursor must survive")
    }

    /// The journal is ORDERED. Partitioning a page into "all upserts, then all
    /// deletes" replays it out of order, and both orders occur: a message
    /// delivered and then deleted, and one deleted and then re-delivered. Fails
    /// on the partitioned version, which gets exactly one of the two backwards.
    @Test("A change page is applied in journal order, not upserts-then-deletes")
    func changePageIsAppliedInOrder() async throws {
        func run(_ changes: [MessageChange], seeded: Bool) async throws -> Bool {
            let api = FakeMailAPIClient()
            await api.setSupportsChanges(true)
            await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
            await api.setChangePages([ChangePage(changes: changes, nextCursor: "c1", hasMore: false)])

            let store = try MailStore.inMemory()
            _ = try await store.upsertMailboxes([SyncFixtures.mailbox("mbx_a")], accountID: account)
            if seeded { _ = try await store.upsertMessages([SyncFixtures.message("m1")], accountID: account) }
            try await seedCheckpoint(store)

            let engine = makeEngine(api, store)
            await engine.start(accountID: account)
            await runOnePass(engine)
            return try await store.message(id: "m1", accountID: account) != nil
        }

        let deliveredThenDeleted = try await run(
            [.upsert(SyncFixtures.message("m1")), .delete(messageID: "m1", mailboxID: "mbx_a")],
            seeded: false
        )
        #expect(deliveredThenDeleted == false, "the delete came last and must win")

        let deletedThenRedelivered = try await run(
            [.delete(messageID: "m1", mailboxID: "mbx_a"), .upsert(SyncFixtures.message("m1"))],
            seeded: true
        )
        #expect(deletedThenRedelivered, "the upsert came last and must win")
    }

    /// The bootstrap listing is the expensive half of a first sync. Persisting
    /// its checkpoint only after the catch-up read meant one flaky `/changes`
    /// call threw the entire listing away and re-listed every mailbox next pass.
    /// Fails on that ordering: the second pass re-lists.
    @Test("The bootstrap checkpoint is persisted before catch-up, so a flaky /changes costs no re-listing")
    func bootstrapCheckpointSurvivesAFailedCatchUp() async throws {
        let api = FakeMailAPIClient()
        await api.setSupportsChanges(true)
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setMessages([SyncFixtures.message("m1")], folder: .inbox)
        // One-shot: the first catch-up read after the listing times out.
        await api.setChangeFailure(.transport(.init(URLError(.timedOut))), forCursor: "chk_0")

        let store = try MailStore.inMemory()
        let engine = makeEngine(api, store)
        await engine.start(accountID: account)
        let outcomes = await runPassOutcomes(engine, count: 2)

        #expect(outcomes == [true, false], "pass 1 fails on catch-up, pass 2 resumes cleanly")
        let checkpoint = try await store.syncCheckpoint(accountID: account)
        #expect(checkpoint?.changeCursor == "chk_0")
        #expect(checkpoint?.bootstrappedAt != nil, "the completed listing must be recorded before catch-up")

        let listings = await api.callCount { if case .listMessages = $0 { return true } else { return false } }
        #expect(listings == 1, "the second pass re-listed a bootstrap it had already completed")
    }

    /// `GET /messages` clamps to `limit` and the engine asks for the server's
    /// maximum. A fake that ignored `limit` could not tell a client asking for
    /// 100 from one asking for 5 — and neither could this suite. Fails if the
    /// engine stops sending a limit, or sends a different one.
    @Test("The engine asks for full 100-row message pages and the server's clamp is honoured")
    func messageListingAsksForTheServerMaximum() async throws {
        let api = FakeMailAPIClient()
        await api.setSupportsChanges(true)
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setMessages(
            (0..<150).map { SyncFixtures.message("m\($0)", threadID: "t\($0)") },
            folder: .inbox
        )

        let store = try MailStore.inMemory()
        let engine = makeEngine(api, store)
        await engine.start(accountID: account)
        await runOnePass(engine)

        #expect(await api.messageLimits() == [SyncEngine.messagePageLimit], "the engine must ask for a full page")
        let cached = try await store.messages(
            accountID: account,
            mailboxID: "mbx_a",
            folder: .inbox,
            limit: 500
        )
        #expect(cached.count == SyncEngine.messagePageLimit, "the fake must clamp to the limit it was sent")
    }
}
