import Foundation
import Testing
@testable import HeraldKit

/// Labels as the v1 API delivers them, on BOTH the servers Herald supports.
///
/// Upstream 1.4.2 answers `includeLabels=true` by embedding `labels` on every
/// `MessageSummary` — listings, the thread route, action results and the
/// `/changes` journal alike — so membership rides in with the rows and the
/// per-label sweep is demoted to a rare reconciliation. Servers at 1.3.4/1.4.0
/// (still supported; production auto-update offered 1.4.0) ignore the parameter
/// and answer without the key, and for those the sweep remains the ONLY
/// membership source, on its original cadence. Which of the two is in force is
/// decided by response shape, never by a version, and the suite below covers both
/// halves — including the direction that would corrupt the cache: reading a
/// missing `labels` key as "this message has no labels".
@Suite("Label sync")
struct LabelSyncTests {
    private static let account = SyncFixtures.account

    static func label(_ id: String, name: String, color: LabelColor = .blue) -> MailLabel {
        MailLabel(
            id: id,
            name: name,
            color: color,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func engine(
        api: FakeMailAPIClient,
        store: MailStore,
        labelPollInterval: Duration = .seconds(3_600),
        reconciliationLabelPollInterval: Duration = .seconds(3_600),
        maxMessagePages: Int = SyncEngine.defaultMaxMessagePages
    ) -> SyncEngine {
        SyncEngine(
            api: api,
            store: store,
            maxMessagePages: maxMessagePages,
            // An hour: nothing in these tests can plausibly elapse the drafts one,
            // so the drafts poll never competes for the assertions.
            draftPollInterval: .seconds(3_600),
            labelPollInterval: labelPollInterval,
            // The idle floor can never be shorter than the visible interval, so it
            // has to follow it or a `.zero` visible interval would still be held to
            // 750s the moment nothing is on screen — which is every test here.
            idleLabelPollInterval: labelPollInterval,
            reconciliationLabelPollInterval: reconciliationLabelPollInterval
        )
    }

    /// Fails if the sweep is put on the message cadence: it is one request PER
    /// LABEL, so a 15-second tick would multiply the poll cost by the workspace's
    /// label count for a surface that changes rarely.
    @Test("Labels are swept on the first pass and not again inside their interval")
    func labelsHaveTheirOwnInterval() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setLabels([Self.label("lbl_1", name: "Billing")])
        let store = try MailStore.inMemory()
        let engine = engine(api: api, store: store)

        await engine.start(accountID: Self.account)
        try await waitUntil("the first pass cached the label") {
            (try? await store.labels(accountID: Self.account))?.count == 1
        }

        await engine.refreshNow()
        try await waitUntil("a second pass ran") {
            await api.callCount { if case .listMailboxes = $0 { return true } else { return false } } >= 2
        }
        #expect(
            await api.callCount { $0 == .listLabels } == 1,
            "a second pass inside the interval must not re-sweep every label"
        )

        // …but opening a label in the sidebar does force a fresh sweep.
        await engine.refreshLabelsNow()
        try await waitUntil("the forced sweep happened") {
            await api.callCount { $0 == .listLabels } == 2
        }
        await engine.stopAndWait()
    }

    /// Fails if membership is merged rather than replaced: the per-label listing
    /// is a COMPLETE statement about that label, so a message the server stopped
    /// returning has lost it and must leave the cache.
    @Test("A label's membership is replaced, so a removed message stops carrying it")
    func membershipIsReplaced() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setLabels([Self.label("lbl_1", name: "Billing")])
        await api.setLabelMessages(
            MessagePage(
                messages: [
                    SyncFixtures.message("msg_1", threadID: "thr_1"),
                    SyncFixtures.message("msg_2", threadID: "thr_2"),
                ],
                nextCursor: nil
            ),
            forLabel: "lbl_1"
        )
        let store = try MailStore.inMemory()
        let engine = engine(api: api, store: store)

        await engine.start(accountID: Self.account)
        try await waitUntil("the first sweep landed both assignments") {
            (try? await store.labelIDsByThread(accountID: Self.account))?.count == 2
        }

        // The second sweep sees only one of them.
        await api.setLabelMessages(
            MessagePage(messages: [SyncFixtures.message("msg_1", threadID: "thr_1")], nextCursor: nil),
            forLabel: "lbl_1"
        )
        await engine.refreshLabelsNow()
        try await waitUntil("the second sweep dropped the message that lost the label") {
            (try? await store.labelIDsByThread(accountID: Self.account))?.count == 1
        }
        let index = try await store.labelIDsByThread(accountID: Self.account)
        #expect(index["thr_1"] == ["lbl_1"])
        #expect(index["thr_2"] == nil, "a thread the listing omitted must lose the label")
        await engine.stopAndWait()
    }

    /// Fails if a truncated page-walk is treated as a complete listing: that
    /// would erase every assignment the server had not got round to returning —
    /// the same trap the message tombstoning rule exists for.
    @Test("A page-capped membership walk leaves the cached assignments alone")
    func truncatedWalkDoesNotErase() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setLabels([Self.label("lbl_1", name: "Billing")])
        await api.setLabelMessages(
            MessagePage(messages: [SyncFixtures.message("msg_1", threadID: "thr_1")], nextCursor: nil),
            forLabel: "lbl_1"
        )
        let store = try MailStore.inMemory()
        let first = engine(api: api, store: store)
        await first.start(accountID: Self.account)
        try await waitUntil("the first sweep landed the assignment") {
            (try? await store.labelIDsByThread(accountID: Self.account))?.isEmpty == false
        }
        await first.stopAndWait()

        // A server that now hands back an endless cursor chain, under a cap of 1.
        await api.setLabelMessages(
            MessagePage(messages: [SyncFixtures.message("msg_9", threadID: "thr_9")], nextCursor: "c1"),
            forLabel: "lbl_1"
        )
        let capped = engine(api: api, store: store, maxMessagePages: 1)
        await capped.start(accountID: Self.account)
        try await waitUntil("the capped sweep ran") {
            await api.callCount {
                if case .listMessagesByLabel = $0 { return true } else { return false }
            } >= 2
        }
        let index = try await store.labelIDsByThread(accountID: Self.account)
        #expect(
            index["thr_1"] == ["lbl_1"],
            "a walk that could not reach the end must not replace the label's membership"
        )
        #expect(index["thr_9"] == nil, "and must not half-apply the pages it did read")
        await capped.stopAndWait()
    }

    /// Fails if label changes ride in `.changed`: those ids are resolved against
    /// the MESSAGE cache by the view-model, and a label id resolves to nothing —
    /// which that code reads as "a brand-new mailbox" and reloads the sidebar for.
    @Test("A label change is emitted as .labelsChanged, and only when something changed")
    func labelsEmitTheirOwnEvent() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setLabels([Self.label("lbl_1", name: "Billing")])
        let store = try MailStore.inMemory()
        let engine = engine(api: api, store: store)
        let recorder = LabelEventRecorder()
        let consumer = Task { await recorder.consume(engine.events) }

        await engine.start(accountID: Self.account)
        try await waitUntil("the first sweep reported the new label") {
            await recorder.labelsChanged == 1
        }

        // A second sweep of identical data must say nothing at all.
        await engine.refreshLabelsNow()
        try await waitUntil("the second sweep finished") { await recorder.finished >= 2 }
        #expect(
            await recorder.labelsChanged == 1,
            "an unchanged sweep must not invalidate the UI"
        )
        await engine.stopAndWait()
        consumer.cancel()
    }

    /// Fails if a 404 (a server older than labels) or a scope refusal is retried
    /// on every pass: it would be a guaranteed extra request per pass, forever,
    /// and — folded into the pass result — a healthy mailbox parked in backoff.
    @Test("A server without labels is probed once and then left alone")
    func missingLabelsRouteIsProbedOnce() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setLabelFailure(.notFound)
        let store = try MailStore.inMemory()
        let engine = engine(api: api, store: store, labelPollInterval: .zero)
        let recorder = LabelEventRecorder()
        let consumer = Task { await recorder.consume(engine.events) }

        await engine.start(accountID: Self.account)
        try await waitUntil("the first pass finished") { await recorder.finished >= 1 }
        // A second pass, asked for explicitly rather than waited out: the label
        // interval is zero here, so only the "probed once" rule can hold the
        // request count at one.
        await engine.refreshNow()
        try await waitUntil("two passes have finished") { await recorder.finished >= 2 }
        #expect(await api.callCount { $0 == .listLabels } == 1)
        #expect(await recorder.failures == 0, "a missing labels route is not a sync failure")
        await engine.stopAndWait()
        consumer.cancel()
    }

    // MARK: - Membership from rows (upstream 1.4.2)

    /// A journal-mode engine whose server has already handed out its checkpoint.
    private func journalAPI(labels: [MailLabel]) async -> FakeMailAPIClient {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setSupportsChanges(true)
        await api.setLabels(labels)
        return api
    }

    /// THE POINT OF THE WHOLE PHASE. Fails if membership still has to be derived
    /// by listing every label: the journal upsert already states what the
    /// message's labels became, so the chips must be right without a single extra
    /// request. A regression here is silent — the chips would still be correct,
    /// just one sweep interval late and at one request per label to get there.
    @Test("A journal upsert carrying labels updates membership, with no sweep")
    func journalLabelsUpdateMembershipWithoutASweep() async throws {
        let billing = Self.label("lbl_1", name: "Billing")
        let api = await journalAPI(labels: [billing])
        let store = try MailStore.inMemory()
        let engine = engine(api: api, store: store)

        await engine.start(accountID: Self.account)
        try await waitUntil("the first pass swept the (empty) label") {
            await api.callCount { if case .listMessagesByLabel = $0 { return true } else { return false } } == 1
        }
        #expect(try await store.labelIDsByThread(accountID: Self.account).isEmpty)

        // Someone labels a message elsewhere: upstream bumps `messages.updated_at`,
        // so it arrives as an ordinary upsert — now carrying the labels.
        await api.setChangePages([
            ChangePage(
                changes: [
                    .upsert(SyncFixtures.message("msg_1", threadID: "thr_1", labels: [billing]))
                ],
                nextCursor: "chk_1",
                hasMore: false
            )
        ])
        await engine.refreshNow()
        try await waitUntil("the journal upsert wrote the membership") {
            (try? await store.labelIDsByThread(accountID: Self.account))?["thr_1"] == ["lbl_1"]
        }
        #expect(
            await api.callCount { if case .listMessagesByLabel = $0 { return true } else { return false } } == 1,
            "membership came from the row; the per-label sweep must not have run again"
        )
        await engine.stopAndWait()
    }

    /// Fails on the ONE mistake that corrupts the cache against a supported
    /// server: reading an absent `labels` key as "this message has no labels".
    /// A 1.3.4/1.4.0 server ignores `includeLabels` and answers without it on
    /// EVERY row, so a `?? []` anywhere on this path would wipe every chip in the
    /// workspace on the first pass — and the sweep would put them back, making it
    /// look like a flicker rather than a bug.
    @Test("A row with no labels key leaves membership alone and keeps the legacy cadence")
    func absentLabelsKeyChangesNothing() async throws {
        let api = await journalAPI(labels: [Self.label("lbl_1", name: "Billing")])
        await api.setLabelMessages(
            MessagePage(messages: [SyncFixtures.message("msg_1", threadID: "thr_1")], nextCursor: nil),
            forLabel: "lbl_1"
        )
        let store = try MailStore.inMemory()
        let engine = engine(api: api, store: store, labelPollInterval: .seconds(3_600))

        await engine.start(accountID: Self.account)
        try await waitUntil("the sweep landed the assignment") {
            (try? await store.labelIDsByThread(accountID: Self.account))?["thr_1"] == ["lbl_1"]
        }

        // The same message comes back through the journal — from a server that
        // never heard of `includeLabels`, so `labels` is nil.
        await api.setChangePages([
            ChangePage(
                changes: [.upsert(SyncFixtures.message("msg_1", threadID: "thr_1", subject: "Edited"))],
                nextCursor: "chk_1",
                hasMore: false
            )
        ])
        await engine.refreshNow()
        try await waitUntil("the upsert landed") {
            (try? await store.message(id: "msg_1", accountID: Self.account))?.subject == "Edited"
        }
        #expect(
            try await store.labelIDsByThread(accountID: Self.account)["thr_1"] == ["lbl_1"],
            "a row that says nothing about labels must not clear them"
        )
        #expect(
            await engine.serverEmbedsLabels == false,
            "nil labels are not evidence of anything — the server stays undetected"
        )
        #expect(
            await engine.currentLabelPollInterval == .seconds(3_600),
            "and the sweep therefore stays on its legacy interval, the only source it has"
        )
        await engine.stopAndWait()
    }

    /// Fails if the demotion is unconditional. The reconciliation interval may
    /// only take over once a row has PROVED the server embeds labels; deciding it
    /// from a version, or up front, would starve a 1.3.4 workspace of the only
    /// membership source it has for half an hour at a time.
    @Test("The reconciliation interval takes over only once a row has embedded labels")
    func embeddingIsDetectedFromTheFirstStatedRow() async throws {
        let billing = Self.label("lbl_1", name: "Billing")
        let api = await journalAPI(labels: [billing])
        let store = try MailStore.inMemory()
        let engine = engine(
            api: api, store: store,
            labelPollInterval: .seconds(120),
            reconciliationLabelPollInterval: .seconds(1_800)
        )

        await engine.start(accountID: Self.account)
        try await waitUntil("the first pass finished its sweep") {
            await api.callCount { $0 == .listLabels } == 1
        }
        #expect(await engine.currentLabelPollInterval == .seconds(120), "undetected until a row says so")

        await api.setChangePages([
            ChangePage(
                // `[]` is a STATEMENT — "this message has no labels" — and counts
                // as proof of the capability just as much as a populated list.
                changes: [.upsert(SyncFixtures.message("msg_1", threadID: "thr_1", labels: []))],
                nextCursor: "chk_1",
                hasMore: false
            )
        ])
        await engine.refreshNow()
        try await waitUntil("the row arrived") {
            (try? await store.message(id: "msg_1", accountID: Self.account)) != nil
        }
        #expect(await engine.serverEmbedsLabels)
        #expect(
            await engine.currentLabelPollInterval == .seconds(1_800),
            "rows are the source now; the sweep drops to the reconciliation interval"
        )
        await engine.stopAndWait()
    }

    /// Fails if a label-list change is answered with a digest-skipped sweep. The
    /// digest suppresses a membership write that matches the previous sweep's own
    /// output, which is right while nothing has moved — but a list that changed
    /// means a label was created, renamed or DELETED, and a deletion is precisely
    /// the event no message row can report, so the full authoritative write has
    /// to happen.
    @Test("A change to the label list forces a full reconciliation")
    func labelListChangeForcesReconciliation() async throws {
        let billing = Self.label("lbl_1", name: "Billing")
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setLabels([billing])
        await api.setLabelMessages(
            MessagePage(messages: [SyncFixtures.message("msg_1", threadID: "thr_1")], nextCursor: nil),
            forLabel: "lbl_1"
        )
        let store = try MailStore.inMemory()
        // Zero: every pass is due, so only the digest can hold the write count
        // down and only the list change can push it back up.
        let engine = engine(api: api, store: store, labelPollInterval: .zero)
        let recorder = LabelEventRecorder()
        let consumer = Task { await recorder.consume(engine.events) }

        await engine.start(accountID: Self.account)
        try await waitUntil("the first sweep wrote the membership") {
            await engine.labelAssignmentWrites == 1
        }

        // A pass over an unchanged workspace: the digest skips the store write.
        await engine.refreshNow()
        try await waitUntil("two passes have finished") { await recorder.finished >= 2 }
        #expect(
            await engine.labelAssignmentWrites == 1,
            "an unmoved membership must not be rewritten"
        )

        // Now the workspace gains a label. The LIST changed, so every label is
        // re-derived — including the one whose digest still matches.
        await api.setLabels([billing, Self.label("lbl_2", name: "Later")])
        await engine.refreshNow()
        try await waitUntil("the reconciliation wrote both labels") {
            await engine.labelAssignmentWrites >= 2
        }
        #expect(
            await engine.labelAssignmentWrites == 3,
            "a list change drops the digests, so both labels are written authoritatively"
        )
        await engine.stopAndWait()
        consumer.cancel()
    }

    /// Fails if demoting the sweep also declawed it. Rows can only ever ADD to
    /// the picture — a message no row mentions keeps whatever the cache last
    /// believed — so the reconciliation must still REPLACE a label's whole set,
    /// which is the only thing that can drop an assignment for a message this
    /// cache does not hold and no journal entry will ever name again.
    @Test("The reconciliation still replaces a label's set on an embedding server")
    func reconciliationStillReplacesOnAnEmbeddingServer() async throws {
        let billing = Self.label("lbl_1", name: "Billing")
        let api = await journalAPI(labels: [billing])
        await api.setLabelMessages(
            MessagePage(
                messages: [
                    SyncFixtures.message("msg_1", threadID: "thr_1", labels: [billing]),
                    // A message in a folder this cache has never listed. Only the
                    // per-label walk will ever mention it.
                    SyncFixtures.message("msg_ghost", threadID: "thr_ghost", labels: [billing]),
                ],
                nextCursor: nil
            ),
            forLabel: "lbl_1"
        )
        let store = try MailStore.inMemory()
        let engine = engine(api: api, store: store)

        await engine.start(accountID: Self.account)
        try await waitUntil("the first sweep landed both assignments") {
            (try? await store.labelIDsByThread(accountID: Self.account))?.count == 2
        }
        // Prove the server is the embedding kind, so this is the demoted path.
        await api.setChangePages([
            ChangePage(
                changes: [.upsert(SyncFixtures.message("msg_1", threadID: "thr_1", labels: [billing]))],
                nextCursor: "chk_1",
                hasMore: false
            )
        ])
        await engine.refreshNow()
        try await waitUntil("the embedding server was detected") { await engine.serverEmbedsLabels }

        // The ghost loses the label. No row will ever say so.
        await api.setLabelMessages(
            MessagePage(
                messages: [SyncFixtures.message("msg_1", threadID: "thr_1", labels: [billing])],
                nextCursor: nil
            ),
            forLabel: "lbl_1"
        )
        await engine.refreshLabelsNow()
        try await waitUntil("the reconciliation dropped it") {
            (try? await store.labelIDsByThread(accountID: Self.account))?["thr_ghost"] == nil
        }
        #expect(
            try await store.labelIDsByThread(accountID: Self.account)["thr_1"] == ["lbl_1"],
            "and left the membership the rows do confirm"
        )
        await engine.stopAndWait()
    }

    // MARK: - The pass's label event (F1/C1)

    /// Fails if `.labelsChanged` is drained only on the success path. A journal
    /// cycle is several pages and each is applied and checkpointed on its own, so
    /// "page 1 wrote labels, page 2 threw" is an ordinary outcome, not an exotic
    /// one — and the membership page 1 wrote is durable. Announcing it only on a
    /// clean pass leaves the chips on screen wrong until the next reconciliation,
    /// which on an embedding server is up to half an hour away.
    @Test("A pass that wrote labels and then failed still announces the labels")
    func labelsChangedSurvivesAFailedPass() async throws {
        let billing = Self.label("lbl_1", name: "Billing")
        let api = await journalAPI(labels: [billing])
        let store = try MailStore.inMemory()
        let engine = engine(api: api, store: store)

        await engine.start(accountID: Self.account)
        try await waitUntil("the bootstrap pass finished") {
            await api.callCount { $0 == .listLabels } == 1
        }

        // Page 1 carries a label edit and says there is more; page 2's cursor
        // fails. The engine has already applied — and checkpointed — page 1.
        await api.setChangePages([
            ChangePage(
                changes: [.upsert(SyncFixtures.message("msg_1", threadID: "thr_1", labels: [billing]))],
                nextCursor: "chk_1",
                hasMore: true
            )
        ])
        await api.setChangeFailure(.server(code: "http_500", message: "boom"), forCursor: "chk_1")

        // Scoped to the SECOND pass. The bootstrap pass emits a `.labelsChanged`
        // of its own (its sweep wrote the label list), so collecting from the
        // start of the stream would let this test pass on that one — i.e. it
        // would stay green with the drain removed, which is the whole point.
        let collected = Task {
            var kinds: [SyncEngineTests.EventKind] = []
            var bootstrapEnded = false
            for await event in engine.events {
                guard bootstrapEnded else {
                    if case .finished = event { bootstrapEnded = true }
                    continue
                }
                kinds.append(SyncEngineTests.EventKind(event))
                if case .failed = event { break }
            }
            return kinds
        }
        await engine.refreshNow()
        let seen = await collected.value

        #expect(
            try await store.labelIDsByThread(accountID: Self.account)["thr_1"] == ["lbl_1"],
            "page 1's membership is in the cache — which is exactly why it must be announced"
        )
        #expect(seen.contains(.labelsChanged), "the failed pass must still drain passLabelsChanged")
        #expect(seen.contains(.failed), "and must still report the failure")
        #expect(
            seen.firstIndex(of: .labelsChanged) ?? .max < seen.firstIndex(of: .failed) ?? .max,
            "chips are corrected before the banner appears"
        )
        await engine.stopAndWait()
    }

    // MARK: - Capability detection across a restart (F1/P4)

    /// Fails if `labelEmbeddingAccounts` outlives the engine's `start()`. The flag
    /// is what demotes the sweep to a half-hourly reconciliation, so an account
    /// that kept it after the server was rolled BACK to 1.3.4/1.4.0 would sweep 15×
    /// more rarely than the only membership source that server has, and the chips
    /// would be wrong for up to half an hour with nothing able to correct them.
    ///
    /// WHAT A GRAPH REINSTALL WITHOUT stop/start DOES: nothing, deliberately. The
    /// set is ENGINE state, so a reinstalled graph builds a brand-new `SyncEngine`
    /// that starts empty and re-decides from its own first row — there is no stale
    /// flag to carry. The case pinned here is the other one: the SAME engine reused
    /// across `stop()`/`start()`, which is what an account switch and an app
    /// re-activation do. `start(accountID:)` returns early for an unchanged account
    /// whose loop is still alive, so the clear only ever runs on a genuine restart.
    @Test("Restarting the engine re-decides whether the server embeds labels")
    func embeddingIsRedecidedOnRestart() async throws {
        let billing = Self.label("lbl_1", name: "Billing")
        let api = await journalAPI(labels: [billing])
        let store = try MailStore.inMemory()
        let engine = engine(
            api: api, store: store,
            labelPollInterval: .seconds(120),
            reconciliationLabelPollInterval: .seconds(1_800)
        )

        await api.setChangePages([
            ChangePage(
                changes: [.upsert(SyncFixtures.message("msg_1", threadID: "thr_1", labels: [billing]))],
                nextCursor: "chk_1",
                hasMore: false
            )
        ])
        await engine.start(accountID: Self.account)
        try await waitUntil("a stated row arrived") { await engine.serverEmbedsLabels }
        #expect(await engine.currentLabelPollInterval == .seconds(1_800))
        // The detection flips inside `flush`, BEFORE the page's cursor is
        // persisted — so stopping on that alone can tear the pass down with the
        // checkpoint still at `chk_0`, and the restarted engine would then read
        // from a cursor this test never staged. Wait for the cursor instead.
        try await waitUntil("the first session persisted its cursor") {
            (try? await store.syncCheckpoint(accountID: Self.account))??.changeCursor == "chk_1"
        }

        await engine.stopAndWait()
        // The server is rolled back: every row now answers WITHOUT the key. The
        // checkpoint the first session persisted is `chk_1`, so the next page has
        // to be keyed there or the restarted engine reads an empty journal.
        await api.setCheckpointCursor("chk_1")
        await api.setChangePages([
            ChangePage(
                changes: [.upsert(SyncFixtures.message("msg_2", threadID: "thr_2"))],
                nextCursor: "chk_2",
                hasMore: false
            )
        ])
        await engine.start(accountID: Self.account)
        #expect(
            await engine.serverEmbedsLabels == false,
            "start() must clear the detection, or a downgraded server keeps the 1800s cadence"
        )
        try await waitUntil("the restarted engine ran a pass") {
            (try? await store.message(id: "msg_2", accountID: Self.account)) != nil
        }
        #expect(
            await engine.currentLabelPollInterval == .seconds(120),
            "and nothing in the new session's rows re-proves the capability"
        )
        await engine.stopAndWait()
    }
}

/// Counts the label-shaped events, and the pass boundary the assertions
/// synchronise on.
private actor LabelEventRecorder {
    private(set) var labelsChanged = 0
    private(set) var finished = 0
    private(set) var failures = 0

    func consume(_ events: AsyncStream<SyncEvent>) async {
        for await event in events {
            switch event {
            case .labelsChanged: labelsChanged += 1
            case .finished: finished += 1
            case .failed: failures += 1
            case .began, .changed, .draftsChanged: break
            }
        }
    }
}

/// The store half: what the cache does with labels once the sweep has written
/// them, and what an optimistic assignment does before the server answers.
@Suite("Label cache")
struct LabelCacheTests {
    private static let account = SyncFixtures.account

    @Test("A label listing crosses folders and shows one row per thread")
    func labelListingCrossesFolders() async throws {
        let store = try MailStore.inMemory()
        // The same thread listed under two scopes — which is normal: a thread in
        // the archive still has its inbox row until the next listing drops it.
        let inbox = SyncFixtures.conversation(threadID: "thr_1")
        try await store.upsertConversations([inbox], accountID: Self.account, mailboxID: "mbx_a", folder: .inbox)
        try await store.upsertConversations([inbox], accountID: Self.account, mailboxID: "mbx_a", folder: .archived)
        let trashed = SyncFixtures.conversation(threadID: "thr_2")
        try await store.upsertConversations([trashed], accountID: Self.account, mailboxID: "mbx_a", folder: .trash)

        try await store.replaceLabels([LabelSyncTests.label("lbl_1", name: "Billing")], accountID: Self.account)
        try await store.replaceAssignments(
            labelID: "lbl_1",
            messages: [
                LabelRowKey(messageID: "msg_1", threadID: "thr_1"),
                LabelRowKey(messageID: "msg_2", threadID: "thr_2"),
            ],
            accountID: Self.account
        )

        let rows = try await store.conversations(withLabel: "lbl_1", accountID: Self.account)
        #expect(rows.map(\.id).sorted() == ["thr_1", "thr_2"], "a label listing spans every folder")
        #expect(rows.count == 2, "a thread listed in two scopes must appear once, not twice")
    }

    /// Fails if a deleted label leaves its assignments behind: nothing else would
    /// ever remove them (the sweep only replaces the sets of labels it re-reads),
    /// so a thread would keep a chip for a label that no longer exists.
    @Test("A label the server stopped listing takes its assignments with it")
    func deletedLabelDropsItsAssignments() async throws {
        let store = try MailStore.inMemory()
        try await store.replaceLabels(
            [LabelSyncTests.label("lbl_1", name: "Billing"), LabelSyncTests.label("lbl_2", name: "Later")],
            accountID: Self.account
        )
        try await store.replaceAssignments(
            labelID: "lbl_2",
            messages: [LabelRowKey(messageID: "msg_1", threadID: "thr_1")],
            accountID: Self.account
        )
        #expect(try await store.labelIDsByThread(accountID: Self.account)["thr_1"] == ["lbl_2"])

        try await store.replaceLabels([LabelSyncTests.label("lbl_1", name: "Billing")], accountID: Self.account)
        #expect(try await store.labels(accountID: Self.account).map(\.id) == ["lbl_1"])
        #expect(
            try await store.labelIDsByThread(accountID: Self.account)["thr_1"] == nil,
            "the deleted label's assignments must go with it"
        )
    }

    /// Fails if an unchanged sweep reports a change: the engine emits on the
    /// boolean, and a always-true one turns every sweep into a UI invalidation.
    @Test("Replacing labels with identical data reports no change")
    func unchangedReplaceReportsNothing() async throws {
        let store = try MailStore.inMemory()
        let labels = [LabelSyncTests.label("lbl_1", name: "Billing")]
        #expect(try await store.replaceLabels(labels, accountID: Self.account))
        #expect(try await store.replaceLabels(labels, accountID: Self.account) == false)
        let rows = [LabelRowKey(messageID: "msg_1", threadID: "thr_1")]
        #expect(try await store.replaceAssignments(labelID: "lbl_1", messages: rows, accountID: Self.account))
        #expect(
            try await store.replaceAssignments(labelID: "lbl_1", messages: rows, accountID: Self.account) == false
        )
    }

    /// The badge rule `replaceAssignments` sets out, made assertable.
    ///
    /// The sweep stores an assignment for every message the LABEL names, which
    /// includes messages in folders this cache has never synced — so the raw row
    /// count legitimately exceeds what the by-label listing can show. Fails if
    /// the badge is built from those rows: it would promise conversations that
    /// opening the label then does not list.
    @Test("The label badge counts what the listing can resolve, not assignment rows")
    func badgeCountsResolvedThreads() async throws {
        let store = try MailStore.inMemory()
        let cached = SyncFixtures.conversation(threadID: "thr_cached")
        try await store.upsertConversations(
            [cached], accountID: Self.account, mailboxID: "mbx_a", folder: .inbox
        )
        // …and the same thread again under a second scope, which is normal and
        // must not be counted twice.
        try await store.upsertConversations(
            [cached], accountID: Self.account, mailboxID: "mbx_a", folder: .archived
        )
        try await store.replaceLabels([LabelSyncTests.label("lbl_1", name: "Billing")], accountID: Self.account)
        try await store.replaceAssignments(
            labelID: "lbl_1",
            messages: [
                LabelRowKey(messageID: "msg_1", threadID: "thr_cached"),
                // A message in a folder Herald has never listed. Real, assigned,
                // and unresolvable.
                LabelRowKey(messageID: "msg_2", threadID: "thr_unsynced"),
            ],
            accountID: Self.account
        )

        let index = try await store.labelIndex(accountID: Self.account)
        #expect(
            index.idsByThread.keys.sorted() == ["thr_cached", "thr_unsynced"],
            "the chips index still holds every assignment — only the COUNT is narrowed"
        )
        #expect(
            index.threadCounts["lbl_1"] == 1,
            "two assignment rows over two threads, but only one the listing can show"
        )
        let listed = try await store.conversations(withLabel: "lbl_1", accountID: Self.account)
        #expect(listed.count == index.threadCounts["lbl_1"], "the badge and the listing agree")
    }

    /// Fails if a label with no assignments reports a count. `nil` and `0` reach
    /// the badge the same way, but an index that returns `.empty` early must not
    /// skip labels that legitimately have zero.
    @Test("A label nobody has used counts zero")
    func unusedLabelCountsZero() async throws {
        let store = try MailStore.inMemory()
        try await store.replaceLabels([LabelSyncTests.label("lbl_1", name: "Billing")], accountID: Self.account)
        let index = try await store.labelIndex(accountID: Self.account)
        #expect(index.threadCounts["lbl_1"] == nil)
        #expect(index.idsByThread.isEmpty)
    }

    /// Fails if the by-label listing loses rows, order or the dedup once the
    /// thread-id filter is chunked. The chunk size is 500 ids, so this crosses it
    /// deliberately: a single chunk comes back sorted by the STORE, several do
    /// not, and a merge that forgot to re-sort would hand the newest threads back
    /// in chunk order.
    @Test("A label spanning more threads than one predicate chunk stays newest-first")
    func chunkedListingKeepsItsOrder() async throws {
        let store = try MailStore.inMemory()
        let total = MailStore.labelPredicateChunkSize + 120
        // Newest LAST in insertion order, so a listing that simply echoed the
        // fetch order would fail this.
        let rows = (0 ..< total).map { index in
            ConversationSummary(
                latest: MessageSummary(
                    id: "msg_\(index)",
                    threadID: "thr_\(index)",
                    mailboxID: "mbx_a",
                    direction: .inbound,
                    folder: .inbox,
                    fromAddress: "ada@example.net",
                    to: ["support@example.com"],
                    subject: "Subject",
                    snippet: "…",
                    receivedAt: Date(timeIntervalSince1970: 2_000 + Double(index)),
                    sentAt: nil,
                    readAt: nil,
                    starredAt: nil,
                    hasAttachments: false,
                    createdAt: Date(timeIntervalSince1970: 2_000 + Double(index))
                ),
                isStarred: false,
                messageCount: 1,
                unreadCount: 1
            )
        }
        try await store.upsertConversations(
            rows, accountID: Self.account, mailboxID: "mbx_a", folder: .inbox
        )
        try await store.replaceLabels([LabelSyncTests.label("lbl_1", name: "Billing")], accountID: Self.account)
        try await store.replaceAssignments(
            labelID: "lbl_1",
            messages: (0 ..< total).map { LabelRowKey(messageID: "msg_\($0)", threadID: "thr_\($0)") },
            accountID: Self.account
        )

        let listed = try await store.conversations(
            withLabel: "lbl_1", accountID: Self.account, limit: 10
        )
        #expect(
            listed.map(\.id) == (0 ..< 10).map { "thr_\(total - 1 - $0)" },
            "the ten newest threads across every chunk, newest first"
        )
        #expect(Set(listed.map(\.id)).count == listed.count, "no thread twice")

        let all = try await store.conversations(
            withLabel: "lbl_1", accountID: Self.account, limit: total + 10
        )
        #expect(all.count == total, "every thread, exactly once")
    }

    /// The `nil` / `[]` contract at the level that enforces it, and the fact that
    /// an embedded write is per-MESSAGE: it may replace the labels of the messages
    /// it names and must touch no other row, or an upsert of one message would
    /// truncate a label's membership the way only a completed sweep may.
    @Test("An embedded-label write is per-message: nil says nothing, [] clears, siblings are untouched")
    func embeddedLabelsAreScopedToTheirMessages() async throws {
        let store = try MailStore.inMemory()
        let billing = LabelSyncTests.label("lbl_1", name: "Billing")
        try await store.replaceLabels([billing], accountID: Self.account)
        try await store.replaceAssignments(
            labelID: "lbl_1",
            messages: [
                LabelRowKey(messageID: "msg_1", threadID: "thr_1"),
                LabelRowKey(messageID: "msg_2", threadID: "thr_2"),
            ],
            accountID: Self.account
        )

        // A row that says NOTHING changes nothing — not even its own message.
        #expect(
            try await store.applyEmbeddedLabels(
                from: [SyncFixtures.message("msg_1", threadID: "thr_1")], accountID: Self.account
            ) == false
        )
        #expect(try await store.labelIDs(messageID: "msg_1", accountID: Self.account) == ["lbl_1"])

        // An EMPTY list is the server saying "no labels", and does clear — but
        // only for the message it names.
        #expect(
            try await store.applyEmbeddedLabels(
                from: [SyncFixtures.message("msg_1", threadID: "thr_1", labels: [])],
                accountID: Self.account
            )
        )
        #expect(try await store.labelIDs(messageID: "msg_1", accountID: Self.account).isEmpty)
        #expect(
            try await store.labelIDs(messageID: "msg_2", accountID: Self.account) == ["lbl_1"],
            "a per-message write must never truncate the label's wider membership"
        )

        // Idempotent: a second pass over the same rows reports no change, so an
        // unchanged poll cannot invalidate the UI.
        let restated = [SyncFixtures.message("msg_2", threadID: "thr_2", labels: [billing])]
        #expect(try await store.applyEmbeddedLabels(from: restated, accountID: Self.account) == false)
    }

    /// Fails if a tombstoned message keeps its assignments: the row would go on
    /// appearing in the label's listing, and nothing would ever clean it up.
    @Test("Deleting a message drops its label assignments")
    func deletedMessageDropsAssignments() async throws {
        let store = try MailStore.inMemory()
        try await store.upsertMessages(
            [SyncFixtures.message("msg_1", threadID: "thr_1")], accountID: Self.account
        )
        try await store.replaceLabels([LabelSyncTests.label("lbl_1", name: "Billing")], accountID: Self.account)
        try await store.replaceAssignments(
            labelID: "lbl_1",
            messages: [LabelRowKey(messageID: "msg_1", threadID: "thr_1")],
            accountID: Self.account
        )
        try await store.deleteMessage(id: "msg_1", accountID: Self.account)
        #expect(try await store.labelIDsByThread(accountID: Self.account).isEmpty)
    }
}

/// The optimistic half: the cache moves first, and a rejection puts back exactly
/// what the optimistic write changed — no more.
@Suite("Label actions")
struct LabelActionTests {
    private static let account = SyncFixtures.account

    private func seededStore() async throws -> MailStore {
        let store = try MailStore.inMemory()
        try await store.upsertMessages(
            [
                SyncFixtures.message("msg_1", threadID: "thr_1"),
                SyncFixtures.message("msg_2", threadID: "thr_1"),
            ],
            accountID: Self.account
        )
        try await store.replaceLabels(
            [LabelSyncTests.label("lbl_1", name: "Billing")], accountID: Self.account
        )
        return store
    }

    @Test("Assigning a label to a conversation writes the cache before the server answers")
    func conversationAssignmentIsOptimistic() async throws {
        let store = try await seededStore()
        let api = FakeMailAPIClient()
        await api.setLabels([LabelSyncTests.label("lbl_1", name: "Billing")])
        let actions = MailActionService(api: api, store: store)

        // The request is HELD open, so the assertion below is about the
        // optimistic write and nothing else — awaiting the whole call first would
        // pass just as well if the cache were only written from the answer.
        await api.armGate()
        let write = Task {
            try await actions.setLabel(
                "lbl_1", onConversation: "thr_1", accountID: Self.account, assigned: true
            )
        }
        try await waitUntil("the optimistic write landed while the request is in flight") {
            (try? await store.labelIDsByThread(accountID: Self.account))?["thr_1"] == ["lbl_1"]
        }
        await api.openGate()
        try await write.value
        #expect(try await store.labelIDsByThread(accountID: Self.account)["thr_1"] == ["lbl_1"])
        // The conversation route takes a MESSAGE id — the same rule the triage
        // actions follow; a thread id resolves to no mailbox and 403s upstream.
        let writes = await api.calls.compactMap { call -> String? in
            if case .setConversationLabel(_, let messageID, _) = call { return messageID }
            return nil
        }
        #expect(writes == ["msg_1"] || writes == ["msg_2"])
    }

    /// Fails if a rejection is left for the next sweep to heal: that is up to two
    /// minutes of a chip the server never accepted.
    @Test("A rejected label change is reverted exactly")
    func rejectionReverts() async throws {
        let store = try await seededStore()
        let api = FakeMailAPIClient()
        await api.setLabelAssignmentFailure(.server(code: "http_403", message: "no"))
        let actions = MailActionService(api: api, store: store)

        await #expect(throws: MailAPIError.self) {
            try await actions.setLabel(
                "lbl_1", onConversation: "thr_1", accountID: Self.account, assigned: true
            )
        }
        #expect(
            try await store.labelIDsByThread(accountID: Self.account).isEmpty,
            "the optimistic chip must be gone once the server refused it"
        )
    }

    /// Fails if the revert takes away a label the action never granted: only the
    /// rows the optimistic write actually CHANGED belong to the undo.
    @Test("A revert leaves a label the action did not add")
    func revertKeepsPreexistingLabels() async throws {
        let store = try await seededStore()
        // msg_1 already carries the label; msg_2 does not.
        try await store.replaceAssignments(
            labelID: "lbl_1",
            messages: [LabelRowKey(messageID: "msg_1", threadID: "thr_1")],
            accountID: Self.account
        )
        let api = FakeMailAPIClient()
        await api.setLabelAssignmentFailure(.server(code: "http_403", message: "no"))
        let actions = MailActionService(api: api, store: store)

        await #expect(throws: MailAPIError.self) {
            try await actions.setLabel(
                "lbl_1", onConversation: "thr_1", accountID: Self.account, assigned: true
            )
        }
        #expect(
            try await store.labelIDs(messageID: "msg_1", accountID: Self.account) == ["lbl_1"],
            "the revert must not remove the assignment that was already there"
        )
        #expect(try await store.labelIDs(messageID: "msg_2", accountID: Self.account).isEmpty)
    }

    /// Fails if a CONVERSATION answer's `labels` is written onto a message row.
    ///
    /// That field is the DISTINCT UNION across the thread, not any one message's
    /// set: applying it to the representative message hands that message labels
    /// only its siblings carry, and strips ones it holds alone. Only the label
    /// that was toggled is authoritative per message.
    @Test("A conversation answer's union is never written onto a single message")
    func conversationAnswerDoesNotOverwriteAMessageSet() async throws {
        let store = try await seededStore()
        try await store.replaceLabels(
            [LabelSyncTests.label("lbl_1", name: "Billing"), LabelSyncTests.label("lbl_2", name: "Later")],
            accountID: Self.account
        )
        // msg_1 carries both labels, msg_2 only the one about to be removed.
        try await store.replaceAssignments(
            labelID: "lbl_1",
            messages: [
                LabelRowKey(messageID: "msg_1", threadID: "thr_1"),
                LabelRowKey(messageID: "msg_2", threadID: "thr_1"),
            ],
            accountID: Self.account
        )
        try await store.replaceAssignments(
            labelID: "lbl_2",
            messages: [LabelRowKey(messageID: "msg_1", threadID: "thr_1")],
            accountID: Self.account
        )

        let api = FakeMailAPIClient()
        // What the real server answers for "remove lbl_1 from the thread": the
        // union of what the thread still carries — which is msg_1's label alone.
        await api.setLabelAssignmentResult(LabelAssignment(
            affected: 2,
            assigned: false,
            labelID: "lbl_1",
            threadID: "thr_1",
            labels: [LabelSyncTests.label("lbl_2", name: "Later")]
        ))
        let actions = MailActionService(api: api, store: store)
        try await actions.setLabel(
            "lbl_1", onConversation: "thr_1", accountID: Self.account, assigned: false
        )

        #expect(try await store.labelIDs(messageID: "msg_1", accountID: Self.account) == ["lbl_2"])
        #expect(
            try await store.labelIDs(messageID: "msg_2", accountID: Self.account).isEmpty,
            "the sibling's label must not be grafted onto the message the request was keyed by"
        )
    }

    /// The server's answer is the full set after the write, which is what lets a
    /// label assigned elsewhere show up without a second request.
    @Test("The server's answer replaces the message's label set")
    func serverAnswerIsAuthoritative() async throws {
        let store = try await seededStore()
        let api = FakeMailAPIClient()
        await api.setLabelAssignmentResult(LabelAssignment(
            affected: 1,
            assigned: true,
            labelID: "lbl_1",
            messageID: "msg_1",
            labels: [
                LabelSyncTests.label("lbl_1", name: "Billing"),
                LabelSyncTests.label("lbl_other", name: "Elsewhere"),
            ]
        ))
        let actions = MailActionService(api: api, store: store)

        try await actions.setLabel("lbl_1", onMessage: "msg_1", accountID: Self.account, assigned: true)
        #expect(
            try await store.labelIDs(messageID: "msg_1", accountID: Self.account).sorted()
                == ["lbl_1", "lbl_other"],
            "a label assigned elsewhere since the last sweep rides in on the answer"
        )
    }

    /// The invariant the upgrade plan calls out by name: a conversation-level PUT
    /// answers with the DISTINCT UNION across the thread, and the union Herald
    /// computes locally — `labelIndex.idsByThread`, which is what the row chips
    /// draw — has to agree with it afterwards. Fails if `settleThreadLabel` writes
    /// the toggled label to only some of the thread's messages, or if the index
    /// double-counts a thread whose messages disagree: either way the chips on the
    /// row would differ from what the server just said the thread carries.
    @Test("The conversation union agrees with the server's answer after a thread PUT")
    func conversationUnionMatchesTheServerAnswer() async throws {
        let store = try await seededStore()
        // msg_1 already carries a second label; msg_2 does not. The thread's union
        // is therefore both labels, and neither message's own set is the union.
        try await store.replaceLabels(
            [
                LabelSyncTests.label("lbl_1", name: "Billing"),
                LabelSyncTests.label("lbl_2", name: "Later"),
            ],
            accountID: Self.account
        )
        try await store.replaceAssignments(
            labelID: "lbl_2",
            messages: [LabelRowKey(messageID: "msg_1", threadID: "thr_1")],
            accountID: Self.account
        )

        let api = FakeMailAPIClient()
        let answer = LabelAssignment(
            affected: 2,
            assigned: true,
            labelID: "lbl_1",
            threadID: "thr_1",
            labels: [
                LabelSyncTests.label("lbl_1", name: "Billing"),
                LabelSyncTests.label("lbl_2", name: "Later"),
            ]
        )
        await api.setLabelAssignmentResult(answer)
        let actions = MailActionService(api: api, store: store)
        try await actions.setLabel(
            "lbl_1", onConversation: "thr_1", accountID: Self.account, assigned: true
        )

        let index = try await store.labelIndex(accountID: Self.account)
        #expect(
            index.idsByThread["thr_1"] == Set(answer.labels.map(\.id)),
            "the locally computed thread union must equal LabelAssignmentResult.labels"
        )
        #expect(
            try await store.labelIDs(messageID: "msg_2", accountID: Self.account) == ["lbl_1"],
            "and the sibling got the toggled label only — not the whole union"
        )
    }

    // MARK: - The label fence (F1/C2)

    /// THE RACE C2 NAMES. `applyEmbeddedLabels` is per-message authoritative, so a
    /// `/changes` page cut BEFORE the user's toggle states the pre-toggle set and
    /// strips the label straight back off — and because every message FIELD is
    /// unchanged, no `.changed` is emitted and nothing re-announces it. The chip
    /// just vanishes until the next reconciliation.
    @Test("A stale journal page does not strip a label whose write is still in flight")
    func staleEmbeddedLabelsCannotStripAnInFlightToggle() async throws {
        let billing = LabelSyncTests.label("lbl_1", name: "Billing")
        let store = try await seededStore()
        let api = FakeMailAPIClient()
        await api.setLabels([billing])
        await api.setLabelAssignmentResult(
            LabelAssignment(
                affected: 1, assigned: true, labelID: "lbl_1", threadID: "thr_1", labels: [billing]
            )
        )
        let actions = MailActionService(api: api, store: store)

        // Hold the POST open: the optimistic write has landed and the fence is up.
        await api.armGate()
        let toggle = Task {
            try await actions.setLabel("lbl_1", onMessage: "msg_1", accountID: Self.account, assigned: true)
        }
        try await waitUntil("the optimistic write landed") {
            (try? await store.labelIDs(messageID: "msg_1", accountID: Self.account)) == ["lbl_1"]
        }
        #expect(await store.hasLabelPin(messageID: "msg_1", labelID: "lbl_1", accountID: Self.account))

        // A page cut before the toggle arrives mid-flight, stating the OLD set.
        try await store.applyMessageUpserts(
            [SyncFixtures.message("msg_1", threadID: "thr_1", labels: [])],
            accountID: Self.account
        )
        #expect(
            try await store.labelIDs(messageID: "msg_1", accountID: Self.account) == ["lbl_1"],
            "the stale page must not strip a label the user just added"
        )

        await api.openGate()
        try await toggle.value
        #expect(
            try await store.labelIDs(messageID: "msg_1", accountID: Self.account) == ["lbl_1"],
            "and the settle leaves it in place"
        )
        #expect(
            await store.hasLabelPin(messageID: "msg_1", labelID: "lbl_1", accountID: Self.account) == false
        )
        // Proof the fence is not permanent: a LATER page is authoritative again.
        try await store.applyMessageUpserts(
            [SyncFixtures.message("msg_1", threadID: "thr_1", labels: [])],
            accountID: Self.account
        )
        #expect(
            try await store.labelIDs(messageID: "msg_1", accountID: Self.account).isEmpty,
            "after the settle the server is authoritative again"
        )
    }

    /// The fence is per PAIR, not per message: pinning the whole row would freeze
    /// every OTHER label on it against the pages that keep those current.
    @Test("The fence covers only the toggled label, not the message's other labels")
    func theFenceIsScopedToItsPair() async throws {
        let billing = LabelSyncTests.label("lbl_1", name: "Billing")
        let later = LabelSyncTests.label("lbl_2", name: "Later")
        let store = try await seededStore()
        try await store.replaceLabels([billing, later], accountID: Self.account)
        let api = FakeMailAPIClient()
        await api.setLabelAssignmentResult(
            LabelAssignment(
                affected: 1, assigned: true, labelID: "lbl_1", threadID: "thr_1", labels: [billing]
            )
        )
        let actions = MailActionService(api: api, store: store)

        await api.armGate()
        let toggle = Task {
            try await actions.setLabel("lbl_1", onMessage: "msg_1", accountID: Self.account, assigned: true)
        }
        try await waitUntil("the optimistic write landed") {
            (try? await store.labelIDs(messageID: "msg_1", accountID: Self.account)) == ["lbl_1"]
        }

        // A page states the pinned label's ABSENCE and an unpinned label's arrival.
        try await store.applyMessageUpserts(
            [SyncFixtures.message("msg_1", threadID: "thr_1", labels: [later])],
            accountID: Self.account
        )
        #expect(
            try await store.labelIDs(messageID: "msg_1", accountID: Self.account).sorted()
                == ["lbl_1", "lbl_2"],
            "the pinned pair survived AND the unpinned one was applied"
        )
        await api.openGate()
        try await toggle.value
    }

    /// A conversation toggle fans out over every cached message of the thread, so
    /// the fence has to as well — including the messages that ALREADY had the
    /// label and so moved no row. Fails if the pins are taken from the undo, which
    /// deliberately carries only the rows that changed.
    @Test("A thread toggle fences every message of the thread, including the unmoved ones")
    func theThreadToggleFencesTheWholeFanOut() async throws {
        let billing = LabelSyncTests.label("lbl_1", name: "Billing")
        let store = try await seededStore()
        // msg_1 already carries the label; only msg_2 will actually move.
        try await store.replaceAssignments(
            labelID: "lbl_1",
            messages: [LabelRowKey(messageID: "msg_1", threadID: "thr_1")],
            accountID: Self.account
        )
        let api = FakeMailAPIClient()
        await api.setLabelAssignmentResult(
            LabelAssignment(
                affected: 1, assigned: true, labelID: "lbl_1", threadID: "thr_1", labels: [billing]
            )
        )
        let actions = MailActionService(api: api, store: store)

        await api.armGate()
        let toggle = Task {
            try await actions.setLabel(
                "lbl_1", onConversation: "thr_1", accountID: Self.account, assigned: true
            )
        }
        try await waitUntil("the optimistic fan-out landed") {
            (try? await store.labelIDs(messageID: "msg_2", accountID: Self.account)) == ["lbl_1"]
        }
        #expect(
            await store.hasLabelPin(messageID: "msg_1", labelID: "lbl_1", accountID: Self.account),
            "a message that already had the label moved no row, but is still in flight"
        )

        try await store.applyMessageUpserts(
            [
                SyncFixtures.message("msg_1", threadID: "thr_1", labels: []),
                SyncFixtures.message("msg_2", threadID: "thr_1", labels: []),
            ],
            accountID: Self.account
        )
        #expect(
            try await store.labelIDs(messageID: "msg_1", accountID: Self.account) == ["lbl_1"],
            "the unmoved message must not be stripped while the thread toggle is in flight"
        )
        #expect(try await store.labelIDs(messageID: "msg_2", accountID: Self.account) == ["lbl_1"])

        await api.openGate()
        try await toggle.value
        #expect(
            await store.hasLabelPin(messageID: "msg_1", labelID: "lbl_1", accountID: Self.account) == false
        )
        #expect(
            await store.hasLabelPin(messageID: "msg_2", labelID: "lbl_1", accountID: Self.account) == false
        )
    }

    /// A pin that outlives its action is worse than the race it prevents: it
    /// fences the pair against the server for the rest of the session, so the
    /// label the server rejected could never be corrected. Fails if the release is
    /// only on the success path.
    @Test("A rejected label change reverts and releases its fence")
    func aRejectedChangeReleasesTheFence() async throws {
        let store = try await seededStore()
        let api = FakeMailAPIClient()
        await api.setLabelAssignmentFailure(.server(code: "http_500", message: "boom"))
        let actions = MailActionService(api: api, store: store)

        await #expect(throws: MailAPIError.self) {
            try await actions.setLabel(
                "lbl_1", onMessage: "msg_1", accountID: Self.account, assigned: true
            )
        }
        #expect(
            try await store.labelIDs(messageID: "msg_1", accountID: Self.account).isEmpty,
            "the optimistic write was reverted"
        )
        #expect(
            await store.hasLabelPin(messageID: "msg_1", labelID: "lbl_1", accountID: Self.account) == false,
            "and the fence came down — a leaked pin blocks the server forever"
        )
        // Proof it really is down: the server's own statement now applies.
        try await store.applyMessageUpserts(
            [SyncFixtures.message(
                "msg_1", threadID: "thr_1", labels: [LabelSyncTests.label("lbl_1", name: "Billing")]
            )],
            accountID: Self.account
        )
        #expect(try await store.labelIDs(messageID: "msg_1", accountID: Self.account) == ["lbl_1"])
    }

    /// The A3 race in its original form: the RECONCILIATION sweep's listing is
    /// also older than a toggle made while it was in flight, and
    /// `replaceAssignments` is authoritative for the whole label. Fails if the
    /// fence stops at the embedded write.
    @Test("A sweep landing mid-toggle does not delete the just-written row")
    func theSweepRespectsTheFence() async throws {
        let billing = LabelSyncTests.label("lbl_1", name: "Billing")
        let store = try await seededStore()
        let api = FakeMailAPIClient()
        await api.setLabelAssignmentResult(
            LabelAssignment(
                affected: 1, assigned: true, labelID: "lbl_1", threadID: "thr_1", labels: [billing]
            )
        )
        let actions = MailActionService(api: api, store: store)

        await api.armGate()
        let toggle = Task {
            try await actions.setLabel("lbl_1", onMessage: "msg_1", accountID: Self.account, assigned: true)
        }
        try await waitUntil("the optimistic write landed") {
            (try? await store.labelIDs(messageID: "msg_1", accountID: Self.account)) == ["lbl_1"]
        }

        // A sweep that started BEFORE the toggle: its listing does not name msg_1.
        try await store.replaceAssignments(labelID: "lbl_1", messages: [], accountID: Self.account)
        #expect(
            try await store.labelIDs(messageID: "msg_1", accountID: Self.account) == ["lbl_1"],
            "the pre-toggle listing must not delete the just-confirmed row"
        )
        await api.openGate()
        try await toggle.value
    }

    // MARK: - Action answers carry membership (F1/P5)

    /// Upstream 1.4.2 embeds labels on the triage-action answer too, and that
    /// answer goes through `applyMessageUpserts` — so a keystroke that only marks
    /// a message read also corrects its chips, for free. Fails if the confirmed
    /// summary is written without its labels, or if a pre-1.4.2 answer
    /// (`labels: nil`) is allowed to clear the set.
    @Test("A triage action's answer updates label membership, and a nil one does not")
    func actionAnswersCarryMembership() async throws {
        let billing = LabelSyncTests.label("lbl_1", name: "Billing")
        let store = try await seededStore()
        let api = FakeMailAPIClient()
        let actions = MailActionService(api: api, store: store)

        await api.setActionResultLabels([billing])
        try await actions.perform(.read, on: "msg_1", accountID: Self.account)
        #expect(
            try await store.labelIDs(messageID: "msg_1", accountID: Self.account) == ["lbl_1"],
            "the action answer's embedded labels reached the store"
        )

        // The same action from a server that does not embed them: the key is
        // absent, which says nothing and must therefore change nothing.
        await api.setActionResultLabels(nil)
        try await actions.perform(.unread, on: "msg_1", accountID: Self.account)
        #expect(
            try await store.labelIDs(messageID: "msg_1", accountID: Self.account) == ["lbl_1"],
            "an answer with no labels key must leave membership alone"
        )
    }
}
