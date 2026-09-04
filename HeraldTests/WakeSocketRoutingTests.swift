import Foundation
import HeraldKit
import Testing
@testable import Herald

/// Records what a wake frame made the view-model ask the sync engine for.
private actor RoutingSync: MailSyncing {
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

/// Records the socket's lifecycle without opening one.
private actor RecordingWake: MailWaking {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}

/// Where each `GET /events` topic lands.
///
/// The mapping is the whole point of the socket: a frame carries no data, so the
/// only thing that makes it useful is asking for the RIGHT re-read. Getting it
/// wrong is invisible in the UI — the poll eventually covers everything — which
/// is exactly why it is pinned here.
@Suite("Wake frame routing")
@MainActor
struct WakeSocketRoutingTests {
    private static func harness() async throws -> (MailViewModel, RoutingSync, RecordingWake) {
        let store = try MailStore.inMemory()
        let api = FakeMailAPIClient()
        let sync = RoutingSync()
        let wake = RecordingWake()
        let (stream, _) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .unbounded)
        let model = MailViewModel(
            accountID: "acct",
            accountLabel: "Test",
            api: api,
            store: store,
            actions: MailActionService(api: api, store: store),
            sync: sync,
            events: stream,
            markReadDelay: .seconds(3_600)
        )
        model.wake = wake
        return (model, sync, wake)
    }

    /// A `messages` frame is a journal pass and nothing else. Fails if it also
    /// forces a label sweep: label MEMBERSHIP changes DO arrive as `messages`
    /// frames (verified against the live 1.3.4 server), and sweeping on each one
    /// would put a request per label behind every read, star and archive in the
    /// workspace.
    @Test("A messages frame asks for a pass, not for drafts or a label sweep")
    func messagesFrame() async throws {
        let (model, sync, _) = try await Self.harness()
        await model.handleWakeSignal(.changed(.messages))
        #expect(await sync.refreshCount == 1)
        #expect(await sync.draftRefreshCount == 0)
        #expect(await sync.labelRefreshCount == 0)
    }

    /// Grants changed. A pass re-lists mailboxes anyway, so this is that pass.
    @Test("A mailboxes frame asks for a pass")
    func mailboxesFrame() async throws {
        let (model, sync, _) = try await Self.harness()
        await model.handleWakeSignal(.changed(.mailboxes))
        #expect(await sync.refreshCount == 1)
        #expect(await sync.draftRefreshCount == 0)
    }

    /// Fails if a draft written elsewhere still waits out the 60-second drafts
    /// interval — the frame exists precisely to skip that wait.
    @Test("A drafts frame forces the drafts read")
    func draftsFrame() async throws {
        let (model, sync, _) = try await Self.harness()
        await model.handleWakeSignal(.changed(.drafts))
        #expect(await sync.draftRefreshCount == 1)
        #expect(await sync.labelRefreshCount == 0)
    }

    /// The `labels` topic is the label LIST (create/rename/delete), which is the
    /// one label change a sweep is the right answer to.
    @Test("A labels frame forces the label sweep")
    func labelsFrame() async throws {
        let (model, sync, _) = try await Self.harness()
        await model.handleWakeSignal(.changed(.labels))
        #expect(await sync.labelRefreshCount == 1)
        #expect(await sync.draftRefreshCount == 0)
    }

    /// Fails if a reconnect only refreshes mail. Frames are not replayed across a
    /// gap, so everything that could have changed while the socket was down —
    /// drafts and labels included — has to be re-read.
    @Test("A reconnect re-reads every surface")
    func reconnectRefreshesEverything() async throws {
        let (model, sync, _) = try await Self.harness()
        await model.handleWakeSignal(.reconnected)
        #expect(await sync.refreshCount == 1)
        #expect(await sync.draftRefreshCount == 1)
        #expect(await sync.labelRefreshCount == 1)
    }

    /// Fails if the socket outlives the app's foreground. A connection held open
    /// behind a closed lid keeps the radio awake for mail nobody is reading, and
    /// the idle poll already covers a backgrounded Herald.
    @Test("The socket follows the app's activation, like the cadence does")
    func socketFollowsActivation() async throws {
        let (model, sync, wake) = try await Self.harness()

        await model.setActive(true)
        #expect(await wake.startCount == 1)
        #expect(await wake.stopCount == 0)

        await model.setActive(false)
        #expect(await wake.stopCount == 1)
        #expect(await sync.cadences == [.active, .idle], "the cadence still follows too")
    }
}
