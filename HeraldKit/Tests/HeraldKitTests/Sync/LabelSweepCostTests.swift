import Foundation
import Testing
@testable import HeraldKit

/// What the label sweep costs when nobody is asking for it.
///
/// The sweep is one `GET /messages?labelId=` page-walk PER label, so at twenty
/// labels it is twenty requests every two minutes for as long as Herald runs —
/// the dominant idle cost of the whole app (A3, the 2026-09-04 surface audit).
/// These pin down the two things that make it affordable: it slows right down
/// when nothing on screen shows labels, and it does not re-write the store for a
/// membership that did not move.
@Suite("Label sweep cost")
struct LabelSweepCostTests {
    private static let account = SyncFixtures.account

    private static func page(_ rows: [(String, String)]) -> MessagePage {
        MessagePage(
            messages: rows.map { SyncFixtures.message($0.0, threadID: $0.1) },
            nextCursor: nil
        )
    }

    // MARK: - Cadence gating

    /// Fails if the sweep runs at its visible cadence forever. The interval is
    /// bought for chips and badges a user can see; a backgrounded Herald, or one
    /// whose workspace has no labels at all, is buying it for nobody.
    @Test("The label interval follows the label surface, and never goes below it")
    func intervalFollowsTheSurface() async throws {
        let engine = SyncEngine(
            api: FakeMailAPIClient(),
            store: try MailStore.inMemory(),
            labelPollInterval: .seconds(120),
            idleLabelPollInterval: .seconds(750)
        )

        #expect(
            await engine.currentLabelPollInterval == .seconds(750),
            "nothing has said the label surface is visible yet"
        )
        await engine.setLabelSurfaceVisible(true)
        #expect(await engine.currentLabelPollInterval == .seconds(120))
        await engine.setLabelSurfaceVisible(false)
        #expect(await engine.currentLabelPollInterval == .seconds(750), "restored at once")

        // The idle interval is a floor on RARITY. A caller that configures it
        // shorter than the visible one must not end up sweeping more often while
        // nobody is looking than while somebody is.
        let inverted = SyncEngine(
            api: FakeMailAPIClient(),
            store: try MailStore.inMemory(),
            labelPollInterval: .seconds(120),
            idleLabelPollInterval: .seconds(30)
        )
        #expect(await inverted.currentLabelPollInterval == .seconds(120))
    }

    /// The behavioural half of the above: a pass inside the IDLE interval but
    /// past the visible one must not sweep while the surface is hidden, and must
    /// sweep once it is shown. Fails if the gate is only cosmetic — if
    /// `isLabelPollDue` still measures against the visible interval.
    @Test("A hidden label surface holds the sweep to the idle interval")
    func hiddenSurfaceSuppressesTheSweep() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setLabels([LabelSyncTests.label("lbl_1", name: "Billing")])
        await api.setLabelMessages(Self.page([("msg_1", "thr_1")]), forLabel: "lbl_1")
        let store = try MailStore.inMemory()
        // Visible cadence effectively zero, idle cadence effectively forever: the
        // ONLY thing that can decide whether a second pass sweeps is the gate.
        let engine = SyncEngine(
            api: api,
            store: store,
            draftPollInterval: .seconds(3_600),
            labelPollInterval: .zero,
            idleLabelPollInterval: .seconds(3_600)
        )

        await engine.start(accountID: Self.account)
        try await waitUntil("the first pass swept (nothing has ever been swept)") {
            await api.callCount { if case .listLabels = $0 { return true } else { return false } } == 1
        }

        await engine.refreshNow()
        try await waitUntil("a second pass ran") {
            await api.callCount { if case .listMailboxes = $0 { return true } else { return false } } >= 2
        }
        #expect(
            await api.callCount { if case .listLabels = $0 { return true } else { return false } } == 1,
            "a hidden label surface must hold the sweep to the idle interval"
        )

        // Now somebody IS looking. The visible interval is zero, so the very next
        // pass owes a sweep.
        await engine.setLabelSurfaceVisible(true)
        await engine.refreshNow()
        try await waitUntil("the visible surface let the sweep run again") {
            await api.callCount { if case .listLabels = $0 { return true } else { return false } } >= 2
        }
        await engine.stopAndWait()
    }

    // MARK: - Unchanged-sweep skip

    /// Fails if every sweep writes. `replaceAssignments` is a fetch, a dictionary
    /// build and a row diff PER LABEL; on a membership nobody touched it is all
    /// of that to change nothing, twenty times over, every two minutes.
    @Test("A sweep whose membership did not move skips the store write")
    func unchangedMembershipSkipsTheWrite() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setLabels([LabelSyncTests.label("lbl_1", name: "Billing")])
        await api.setLabelMessages(
            Self.page([("msg_1", "thr_1"), ("msg_2", "thr_2")]), forLabel: "lbl_1"
        )
        let store = try MailStore.inMemory()
        let engine = SyncEngine(
            api: api,
            store: store,
            draftPollInterval: .seconds(3_600),
            labelPollInterval: .zero,
            idleLabelPollInterval: .zero
        )
        await engine.setLabelSurfaceVisible(true)

        await engine.start(accountID: Self.account)
        try await waitUntil("the first sweep wrote the membership") {
            (try? await store.labelIDsByThread(accountID: Self.account))?.count == 2
        }
        #expect(await engine.labelAssignmentWrites == 1)

        // A second sweep of the SAME rows — in a different order, because the
        // server promises none and a digest that depended on it would be useless.
        await api.setLabelMessages(
            Self.page([("msg_2", "thr_2"), ("msg_1", "thr_1")]), forLabel: "lbl_1"
        )
        await engine.refreshNow()
        try await waitUntil("a second sweep ran") {
            await api.callCount { if case .listLabels = $0 { return true } else { return false } } >= 2
        }
        #expect(
            await engine.labelAssignmentWrites == 1,
            "an identical membership must not be written again"
        )

        // …and a membership that DID move is written, or the skip would be a
        // cache that never updates again.
        await api.setLabelMessages(Self.page([("msg_1", "thr_1")]), forLabel: "lbl_1")
        await engine.refreshNow()
        try await waitUntil("the changed membership was written") {
            await engine.labelAssignmentWrites == 2
        }
        try await waitUntil("and the store followed") {
            (try? await store.labelIDsByThread(accountID: Self.account))?.count == 1
        }
        await engine.stopAndWait()
    }

    /// Fails if `refreshLabelsNow()` can be answered from the digest. It is the
    /// "the user is asking about labels RIGHT NOW" path — opening a label,
    /// pressing Refresh inside one — and it is the only way a cache that drifted
    /// out of step with the server (a local write the server never took, a sweep
    /// that raced a toggle) is ever put right.
    @Test("An explicit label refresh always writes, digest or no digest")
    func explicitRefreshBypassesTheDigest() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setLabels([LabelSyncTests.label("lbl_1", name: "Billing")])
        await api.setLabelMessages(Self.page([("msg_1", "thr_1")]), forLabel: "lbl_1")
        let store = try MailStore.inMemory()
        let engine = SyncEngine(
            api: api,
            store: store,
            draftPollInterval: .seconds(3_600),
            labelPollInterval: .zero,
            idleLabelPollInterval: .zero
        )
        await engine.setLabelSurfaceVisible(true)

        await engine.start(accountID: Self.account)
        try await waitUntil("the first sweep wrote") { await engine.labelAssignmentWrites == 1 }

        await engine.refreshLabelsNow()
        try await waitUntil("the forced sweep wrote again despite an identical membership") {
            await engine.labelAssignmentWrites == 2
        }
        await engine.stopAndWait()
    }

    /// Fails if a page-capped walk poisons the digest. A capped walk is a
    /// deliberate NON-write (a truncated listing would erase assignments the
    /// server never got round to returning); recording a digest for it would make
    /// the next COMPLETE walk that happens to match look like a no-op and skip
    /// the write the cache has been waiting for.
    @Test("A skipped walk records no digest")
    func cappedWalkLeavesTheDigestAlone() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setLabels([LabelSyncTests.label("lbl_1", name: "Billing")])
        // A full-cap page with no cursor from a server that has never paginated:
        // the walk cannot tell a complete listing from a truncated one, so it
        // refuses to write.
        await api.setLabelMessages(
            MessagePage(
                messages: (0 ..< SyncEngine.serverMessageListCap).map {
                    SyncFixtures.message("msg_\($0)", threadID: "thr_\($0)")
                },
                nextCursor: nil
            ),
            forLabel: "lbl_1"
        )
        let store = try MailStore.inMemory()
        let engine = SyncEngine(
            api: api,
            store: store,
            draftPollInterval: .seconds(3_600),
            labelPollInterval: .zero,
            idleLabelPollInterval: .zero
        )
        await engine.setLabelSurfaceVisible(true)

        await engine.start(accountID: Self.account)
        try await waitUntil("the capped sweep ran") {
            await api.callCount { if case .listLabels = $0 { return true } else { return false } } >= 1
        }
        #expect(await engine.labelAssignmentWrites == 0, "a capped walk must not write")
        #expect(try await store.labelIDsByThread(accountID: Self.account).isEmpty)

        // The server paginates now, so the SAME rows arrive as a complete listing
        // and must be written — a digest recorded for the capped walk would have
        // swallowed exactly this.
        await api.setLabelMessages(Self.page([("msg_1", "thr_1")]), forLabel: "lbl_1")
        await engine.refreshNow()
        try await waitUntil("the complete listing was written") {
            (try? await store.labelIDsByThread(accountID: Self.account))?.count == 1
        }
        await engine.stopAndWait()
    }
}
