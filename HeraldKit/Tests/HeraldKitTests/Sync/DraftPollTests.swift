import Foundation
import Testing
@testable import HeraldKit

/// The drafts poll as the ``SyncEngine`` runs it: its own interval, its own
/// event, and its own failure mode.
@Suite("Draft polling")
struct DraftPollTests {
    private static let account = SyncFixtures.account

    private func engine(
        api: FakeMailAPIClient,
        store: MailStore,
        draftPollInterval: Duration
    ) -> SyncEngine {
        SyncEngine(api: api, store: store, draftPollInterval: draftPollInterval)
    }

    /// Fails if the drafts list is polled on the MESSAGE cadence. `GET /drafts`
    /// is a whole-list read with no pagination and no journal entry, so putting
    /// it on the 15-second tick is a third full request per tick for a folder
    /// nobody is usually looking at.
    @Test("Drafts are polled on the first pass and not again inside their interval")
    func draftsHaveTheirOwnInterval() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setDrafts([DraftSyncTests.draft(id: "dft_1", version: 1)])
        let store = try MailStore.inMemory()
        // An hour: nothing in this test can plausibly elapse it.
        let engine = engine(api: api, store: store, draftPollInterval: .seconds(3_600))

        await engine.start(accountID: Self.account)
        try await waitUntil("the first pass reconciled the drafts") {
            (try? await store.draftCount(accountID: Self.account)) == 1
        }

        await engine.refreshNow()
        try await waitUntil("a second pass ran") {
            await api.callCount { if case .listMailboxes = $0 { return true } else { return false } } >= 2
        }
        #expect(
            await api.callCount { $0 == .listDrafts } == 1,
            "a second pass inside the interval must not re-read the whole drafts list"
        )

        // …but asking for drafts explicitly (opening the folder) does re-read.
        await engine.refreshDraftsNow()
        try await waitUntil("the forced drafts refresh happened") {
            await api.callCount { $0 == .listDrafts } == 2
        }
        await engine.stopAndWait()
    }

    /// Fails if draft changes ride in `.changed`: the view-model resolves those
    /// ids against the MESSAGE cache, so a draft id would resolve to nothing and
    /// be mistaken for a brand-new mailbox, reloading the sidebar on every draft
    /// edit.
    @Test("A draft change is emitted as .draftsChanged, and only when something changed")
    func draftsEmitTheirOwnEvent() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([])
        await api.setDrafts([DraftSyncTests.draft(id: "dft_1", version: 1)])
        let store = try MailStore.inMemory()
        let engine = engine(api: api, store: store, draftPollInterval: .zero)

        let recorder = EventRecorder()
        let events = engine.events
        let collector = Task { await recorder.consume(events) }

        await engine.start(accountID: Self.account)
        try await waitUntil("the drafts landed") { (try? await store.draftCount(accountID: Self.account)) == 1 }
        // A second pass over an unchanged list must say nothing at all.
        await engine.refreshNow()
        // The COLLECTOR, not the engine, is what the counts below are read from,
        // and the event stream is buffered — so the drain has to be waited for.
        // `.finished` is the last event of a pass: seeing two of them means
        // everything both passes emitted is already counted. Cancelling the
        // collector and asserting (which is what this did) reads whatever it
        // happened to have drained, and a negative assertion passes vacuously.
        //
        // And it is waited for BEFORE the stop: `stopAndWait` cancels the pass in
        // flight, so a `.finished` that has not been emitted yet never will be.
        try await waitUntil("the collector drained both passes") { await recorder.finished >= 2 }
        await engine.stopAndWait()
        collector.cancel()

        #expect(await recorder.draftsChanged == 1, "an unchanged drafts listing must emit nothing")
        #expect(await recorder.draftsInserted == ["dft_1"])
        #expect(await recorder.changed == 0, "drafts must never be reported as message changes")
    }

    /// Fails if a drafts failure is folded into the pass result. `GET /drafts`
    /// needs the `mail:send` scope: an account consented without it would answer
    /// 403 on every pass, park a perfectly healthy mailbox in exponential backoff
    /// and show a permanent "Sync problem" banner.
    @Test("A drafts route the account cannot read does not fail the mail pass")
    func draftFailureIsNotAPassFailure() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setDraftListFailure(.insufficientScope("mail:send"))
        let store = try MailStore.inMemory()
        let engine = engine(api: api, store: store, draftPollInterval: .zero)

        let recorder = EventRecorder()
        let events = engine.events
        let collector = Task { await recorder.consume(events) }

        await engine.start(accountID: Self.account)
        try await waitUntil("two passes ran") {
            await api.callCount { if case .listMailboxes = $0 { return true } else { return false } } >= 1
        }
        await engine.refreshNow()
        try await waitUntil("a second pass ran") {
            await api.callCount { if case .listMailboxes = $0 { return true } else { return false } } >= 2
        }
        // Same reason as above, and it matters more here: the payoff assertion is
        // NEGATIVE, so an undrained collector reports zero failures and the test
        // goes green with the bug present.
        try await waitUntil("the collector drained both passes") { await recorder.finished >= 2 }
        await engine.stopAndWait()
        collector.cancel()

        #expect(await recorder.failures == 0, "a drafts refusal is not a sync failure")
        #expect(
            await api.callCount { $0 == .listDrafts } == 1,
            "an account that cannot read drafts must not be asked again every pass"
        )
    }

}

/// Counts what the engine emitted, off the test's own isolation.
///
/// An actor rather than local `var`s mutated inside the collector task: those
/// were read from the test body with no synchronisation at all, which is a data
/// race on top of the ordering one.
private actor EventRecorder {
    private(set) var draftsChanged = 0
    private(set) var draftsInserted: Set<String> = []
    private(set) var changed = 0
    private(set) var failures = 0
    /// The pass boundary the assertions synchronise on.
    private(set) var finished = 0

    func consume(_ events: AsyncStream<SyncEvent>) async {
        for await event in events {
            switch event {
            case .draftsChanged(let changes):
                draftsChanged += 1
                draftsInserted.formUnion(changes.inserted)
            case .changed: changed += 1
            case .failed: failures += 1
            case .finished: finished += 1
            case .began: break
            }
        }
    }
}
