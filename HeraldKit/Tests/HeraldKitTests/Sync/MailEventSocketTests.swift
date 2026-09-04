import Foundation
import Testing
@testable import HeraldKit

/// What one scripted connection does.
enum FakeConnection: Sendable {
    /// The upgrade fails.
    case rejected(MailEventChannelError)
    /// The upgrade succeeds, the frames are delivered in order, and then the
    /// connection ends with `then`.
    case accepted(frames: [String], then: MailEventChannelError)
    /// The upgrade succeeds and the connection stays open until the socket is
    /// stopped. Always the LAST entry of a script: it parks the loop.
    case parked(frames: [String])
}

/// Hands out scripted connections and records the tokens they were opened with.
actor FakeMailEventChannels: MailEventChannelOpening {
    private var script: [FakeConnection]
    private(set) var tokens: [String] = []

    init(_ script: [FakeConnection]) {
        self.script = script
    }

    var openCount: Int { tokens.count }

    nonisolated func open(token: String) async throws -> any MailEventChannel {
        try await next(token: token)
    }

    private func next(token: String) async throws -> any MailEventChannel {
        tokens.append(token)
        // A script that runs out parks, rather than spinning the reconnect loop
        // at full speed for the rest of the test.
        let step = script.isEmpty ? FakeConnection.parked(frames: []) : script.removeFirst()
        switch step {
        case .rejected(let error):
            throw error
        case .accepted(let frames, let end):
            return FakeChannel(frames: frames, end: end)
        case .parked(let frames):
            return FakeChannel(frames: frames, end: nil)
        }
    }
}

/// One scripted connection.
///
/// A channel with no scripted ending PARKS its `receive()`, exactly as a healthy
/// socket does, and ONLY `close()` frees it.
///
/// Deliberately NOT cancellation-aware, because the real channel is not:
/// `URLSessionWebSocketTask.receive()` is a bridged completion-handler call that
/// ignores Task cancellation. An earlier version of this fake unblocked on
/// cancellation, which made the receive watchdog's test pass against a watchdog
/// that could never have fired in production. A fake that is easier to escape
/// than the real thing tests nothing.
private nonisolated final class FakeChannel: MailEventChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [String]
    private let end: MailEventChannelError?
    private var parked: CheckedContinuation<String, any Error>?
    private var isClosed = false

    init(frames: [String], end: MailEventChannelError?) {
        self.frames = frames
        self.end = end
    }

    func receive() async throws -> String {
        let next: String? = lock.withLock { frames.isEmpty ? nil : frames.removeFirst() }
        if let next { return next }
        if let end { throw end }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            lock.lock()
            if isClosed {
                lock.unlock()
                continuation.resume(throwing: MailEventChannelError.closed(code: nil))
            } else {
                parked = continuation
                lock.unlock()
            }
        }
    }

    func close() {
        lock.lock()
        isClosed = true
        let waiting = parked
        parked = nil
        lock.unlock()
        waiting?.resume(throwing: MailEventChannelError.closed(code: nil))
    }
}

/// Collects the socket's signals in order.
actor SignalRecorder {
    private(set) var signals: [MailEventSignal] = []
    private(set) var health: [Bool] = []
    private(set) var reauthCount = 0

    func record(_ signal: MailEventSignal) { signals.append(signal) }
    func record(health value: Bool) { health.append(value) }
    func recordReauth() { reauthCount += 1 }
}

/// A wait the test opens and closes by hand. Not cancellation-aware on purpose:
/// it stands in for work the teardown genuinely has to wait out.
actor Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var isWaiting = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            isWaiting = true
            waiting.append(continuation)
        }
    }

    func release() {
        let parked = waiting
        waiting = []
        isWaiting = false
        for continuation in parked { continuation.resume() }
    }
}

/// Records the delays the reconnect policy asked for.
actor SleepRecorder {
    private(set) var delays: [Duration] = []
    func record(_ duration: Duration) { delays.append(duration) }
}

/// The wake socket: `GET /events` frames, the reconnect policy, and the one
/// token refresh it is allowed.
@Suite("Mail event wake socket")
struct MailEventSocketTests {
    // MARK: - Frames

    @Test(
        "A changed frame maps to its topic",
        arguments: [
            ("{\"type\":\"changed\",\"topic\":\"messages\"}", MailEventTopic.messages),
            ("{\"type\":\"changed\",\"topic\":\"drafts\"}", .drafts),
            ("{\"type\":\"changed\",\"topic\":\"mailboxes\"}", .mailboxes),
            ("{\"type\":\"changed\",\"topic\":\"labels\"}", .labels)
        ]
    )
    func framesDecode(frame: String, expected: MailEventTopic) {
        #expect(MailEventSocket.topic(inFrame: frame) == expected)
    }

    /// Fails if an unrecognized frame is treated as an error. The server is free
    /// to add topics and message types, and a client that dropped the connection
    /// on them would be disconnected for good by a server upgrade.
    @Test(
        "Anything that is not a known changed frame is ignored, not an error",
        arguments: [
            "{\"type\":\"changed\",\"topic\":\"calendars\"}",
            "{\"type\":\"hello\",\"topic\":\"messages\"}",
            "{\"type\":\"changed\"}",
            "not json at all",
            ""
        ]
    )
    func unknownFramesAreIgnored(frame: String) {
        #expect(MailEventSocket.topic(inFrame: frame) == nil)
    }

    // MARK: - Signals

    /// Every frame becomes exactly one wake, and connecting is itself a wake:
    /// nothing is replayed across a gap, so a fresh socket means "re-read
    /// everything".
    @Test("Connecting signals a reconnect, and each frame signals its topic")
    func framesBecomeSignals() async throws {
        let recorder = SignalRecorder()
        let channels = FakeMailEventChannels([
            .parked(frames: [
                "{\"type\":\"changed\",\"topic\":\"messages\"}",
                "{\"type\":\"changed\",\"topic\":\"labels\"}"
            ])
        ])
        let socket = Self.socket(channels: channels, recorder: recorder)

        await socket.start()
        try await waitUntil("both frames arrived") { await recorder.signals.count == 3 }
        await socket.stop()

        #expect(await recorder.signals == [.reconnected, .changed(.messages), .changed(.labels)])
        #expect(await recorder.health == [true, false], "the socket reports health both ways")
    }

    // MARK: - Authentication

    /// Fails if the socket answers a 401 the way the REST middleware does not:
    /// one refresh, one retry, with the token that was actually rejected.
    @Test("A 401 at the upgrade refreshes the token once and retries")
    func unauthorizedRefreshesOnce() async throws {
        let recorder = SignalRecorder()
        let tokens = FakeTokenProvider(initial: "token-1", refreshedTokens: ["token-2"])
        let channels = FakeMailEventChannels([.rejected(.unauthorized), .parked(frames: [])])
        let socket = Self.socket(channels: channels, tokens: tokens, recorder: recorder)

        await socket.start()
        try await waitUntil("the retry connected") { await recorder.signals == [.reconnected] }
        await socket.stop()

        #expect(await channels.tokens == ["token-1", "token-2"])
        #expect(await tokens.refreshCallCount == 1, "exactly one refresh, never a loop of them")
        #expect(await recorder.reauthCount == 0)
    }

    /// Fails if a dead session leaves the socket retrying forever: every attempt
    /// spends another doomed request, and only the UI can fix it.
    @Test("A 401 that survives the refresh escalates to re-authentication and stops")
    func unauthorizedTwiceEscalates() async throws {
        let recorder = SignalRecorder()
        let channels = FakeMailEventChannels([.rejected(.unauthorized), .rejected(.unauthorized)])
        let socket = Self.socket(channels: channels, recorder: recorder)

        await socket.start()
        try await waitUntil("the escalation happened") { await recorder.reauthCount == 1 }
        // Nothing more may be attempted after the escalation.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await channels.openCount == 2)
        #expect(await recorder.signals.isEmpty)
        await socket.stop()
    }

    /// Same rule for the refresh itself failing: a dead grant is not a network
    /// blip and reconnecting cannot mend it.
    @Test("A refresh that reports a dead grant escalates instead of reconnecting")
    func deadGrantEscalates() async throws {
        let recorder = SignalRecorder()
        let tokens = FakeTokenProvider()
        await tokens.setRefreshFailure(OAuthError.reauthenticationRequired)
        let channels = FakeMailEventChannels([.rejected(.unauthorized)])
        let socket = Self.socket(channels: channels, tokens: tokens, recorder: recorder)

        await socket.start()
        try await waitUntil("the escalation happened") { await recorder.reauthCount == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await channels.openCount == 1)
        await socket.stop()
    }

    // MARK: - Reconnect policy

    /// The ten-minute lease ending is the NORMAL case, not a failure. Fails if it
    /// ratchets the backoff up: a healthy client would drift to two-minute
    /// reconnect gaps within the hour, with the poll stretched behind it.
    @Test("A lease that ran its course reconnects promptly and does not back off")
    func leaseEndDoesNotBackOff() async throws {
        let recorder = SignalRecorder()
        let sleeps = SleepRecorder()
        let clock = TestInstant()
        let frame = "{\"type\":\"changed\",\"topic\":\"messages\"}"
        // Two full leases in a row, then park. If a lease end counted as a
        // failure the SECOND delay would be larger than the first.
        let channels = FakeMailEventChannels([
            .accepted(frames: [frame], then: .closed(code: 1_008)),
            .accepted(frames: [frame], then: .closed(code: 1_008)),
            .parked(frames: [])
        ])
        let socket = MailEventSocket(
            channels: channels,
            tokens: FakeTokenProvider(),
            baseBackoff: .seconds(10),
            healthyConnectionDuration: .seconds(60),
            sleep: { await sleeps.record($0) },
            watchdogSleep: Self.neverReturns,
            jitter: { 0.5 },
            now: { clock.value },
            healthChanged: { await recorder.record(health: $0) },
            signal: { signal in
                // The frame stands in for "this connection was up for its whole
                // lease": the clock only moves when the test says so.
                if signal == .changed(.messages) { clock.advance(by: .seconds(600)) }
                await recorder.record(signal)
            }
        )

        await socket.start()
        try await waitUntil("both leases ran and it reconnected twice") {
            await channels.openCount == 3
        }
        await socket.stop()

        #expect(
            await sleeps.delays == [.seconds(5), .seconds(5)],
            "a lease end waits the jittered base delay every time, never a growing backoff (a failure at this base would be 7.5s)"
        )
    }

    /// Fails if a server that keeps refusing is hammered. The poll loop is
    /// carrying the app meanwhile, so patience here costs the user nothing.
    @Test("Repeated failures back off exponentially, capped")
    func failuresBackOff() async throws {
        let sleeps = SleepRecorder()
        let channels = FakeMailEventChannels([
            .rejected(.rejected(status: 503)),
            .rejected(.rejected(status: 503)),
            .rejected(.rejected(status: 503)),
            .rejected(.rejected(status: 503)),
            .parked(frames: [])
        ])
        let socket = MailEventSocket(
            channels: channels,
            tokens: FakeTokenProvider(),
            baseBackoff: .seconds(2),
            maxBackoff: .seconds(8),
            sleep: { await sleeps.record($0) },
            watchdogSleep: Self.neverReturns,
            // Full jitter, pinned to its maximum: the ladder is then exactly the
            // capped delay and the assertion says something.
            jitter: { 1.0 },
            signal: { _ in }
        )

        await socket.start()
        try await waitUntil("every scripted refusal was attempted") { await channels.openCount == 5 }
        await socket.stop()

        #expect(
            await sleeps.delays == [.seconds(2), .seconds(4), .seconds(8), .seconds(8)],
            "doubling, then held at the cap"
        )
    }

    /// Fails if the jitter is decorative. Two clients whose leases end together
    /// (which is what a ten-minute lease does to a fleet) must not reconnect in
    /// the same instant.
    @Test("The delay is jittered, not fixed")
    func delayIsJittered() async throws {
        let sleeps = SleepRecorder()
        let channels = FakeMailEventChannels([
            .rejected(.rejected(status: 503)),
            .parked(frames: [])
        ])
        let socket = MailEventSocket(
            channels: channels,
            tokens: FakeTokenProvider(),
            baseBackoff: .seconds(10),
            sleep: { await sleeps.record($0) },
            watchdogSleep: Self.neverReturns,
            jitter: { 0 },
            signal: { _ in }
        )
        await socket.start()
        try await waitUntil("the retry happened") { await channels.openCount == 2 }
        await socket.stop()

        #expect(
            await sleeps.delays == [.seconds(5)],
            "half the delay is fixed and half is spread, so jitter 0 halves it"
        )
    }

    /// Fails if a socket that goes silent without closing keeps the poll loop
    /// stretched: a half-open connection (lid closed, network switched) leaves
    /// `receive()` parked forever, and the server would have closed at ten
    /// minutes.
    @Test("A connection that goes silent past the lease window is rebuilt")
    func silentConnectionIsRebuilt() async throws {
        let recorder = SignalRecorder()
        let channels = FakeMailEventChannels([.parked(frames: []), .parked(frames: [])])
        let socket = MailEventSocket(
            channels: channels,
            tokens: FakeTokenProvider(),
            receiveTimeout: .milliseconds(20),
            sleep: { _ in },
            jitter: { 0 },
            signal: { await recorder.record($0) }
        )

        await socket.start()
        try await waitUntil("the watchdog rebuilt the connection") { await channels.openCount >= 2 }
        await socket.stop()
        #expect(await recorder.signals.filter { $0 == .reconnected }.count >= 2)
    }

    /// Fails if a stop/start pair can leave TWO loops running. `stop()` suspends
    /// while it waits for its loop to unwind, which releases the actor — and the
    /// app produces exactly this sequence whenever a resign-active is followed
    /// straight by a become-active. Two loops mean two connections for one
    /// account against the server's three-per-user cap (it evicts the oldest),
    /// and the outgoing loop clearing the incoming one's channel would orphan a
    /// live socket that nothing can close.
    @Test("Restarting while a stop is unwinding leaves exactly one live connection")
    func stopAndStartDoNotOverlap() async throws {
        let recorder = SignalRecorder()
        let channels = FakeMailEventChannels([
            // Ends at once, so the loop is sitting in its backoff sleep — an
            // uninterruptible one, which is what holds `stop()` inside its await
            // long enough for the `start()` below to land in the window.
            .accepted(frames: [], then: .closed(code: nil)),
            .parked(frames: [])
        ])
        // The gate holds the loop inside its backoff wait, so the teardown window
        // is opened by the TEST rather than by a sleep a loaded machine can lose.
        let gate = Gate()
        let socket = MailEventSocket(
            channels: channels,
            tokens: FakeTokenProvider(),
            sleep: { _ in await gate.wait() },
            watchdogSleep: Self.neverReturns,
            jitter: { 0 },
            healthChanged: { await recorder.record(health: $0) },
            signal: { await recorder.record($0) }
        )

        await socket.start()
        try await waitUntil("the first connection ended and the loop is in backoff") {
            await gate.isWaiting
        }

        let stopping = Task { await socket.stop() }
        try await waitUntil("the teardown is parked waiting for the loop") {
            await socket.isTearingDown
        }
        // THE point of the test: this start lands inside that window.
        await socket.start()
        await gate.release()
        await stopping.value

        try await waitUntil("the handed-over start took effect") { await channels.openCount == 2 }
        #expect(await socket.isConnected, "the surviving loop must still report itself healthy")
        await socket.stop()
        #expect(await socket.isConnected == false)
        #expect(await channels.openCount == 2, "no third connection was opened")
    }

    // MARK: - Helpers

    /// A wait that only ends when its task is cancelled — the watchdog's default
    /// behaviour for tests that are not about the watchdog.
    static let neverReturns: @Sendable (Duration) async throws -> Void = { _ in
        try await Task.sleep(for: .seconds(3_600))
    }

    private static func socket(
        channels: FakeMailEventChannels,
        tokens: FakeTokenProvider = FakeTokenProvider(),
        recorder: SignalRecorder
    ) -> MailEventSocket {
        MailEventSocket(
            channels: channels,
            tokens: tokens,
            sleep: { _ in },
            watchdogSleep: neverReturns,
            jitter: { 0 },
            healthChanged: { await recorder.record(health: $0) },
            reauthenticationRequired: { await recorder.recordReauth() },
            signal: { await recorder.record($0) }
        )
    }
}

/// A hand-driven `ContinuousClock.Instant`, so "how long was this connection
/// up?" is decided by the test rather than by how fast the machine ran.
///
/// A lock rather than an actor because the socket reads it from a synchronous
/// `@Sendable` closure, which cannot await.
nonisolated final class TestInstant: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: ContinuousClock.Instant = .now

    var value: ContinuousClock.Instant { lock.withLock { instant } }

    func advance(by duration: Duration) {
        lock.withLock { instant = instant.advanced(by: duration) }
    }
}
