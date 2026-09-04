import Foundation
import OSLog

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "MailEvents")

/// A topic the server's wake socket reports on.
///
/// Wake-only: a frame says "something under this topic changed" and carries no
/// mail data and no cursor, so every frame is answered by reading the
/// authoritative REST resource or journal.
public nonisolated enum MailEventTopic: String, Sendable, CaseIterable {
    case messages
    case drafts
    case mailboxes
    case labels
}

/// What the socket tells its owner.
public nonisolated enum MailEventSignal: Sendable, Hashable {
    /// A `changed` frame for one topic.
    case changed(MailEventTopic)
    /// The socket (re)connected. Frames are not durable and nothing is replayed
    /// across a gap, so a fresh connection means "you may have missed
    /// everything" — the owner has to re-read every surface, not just messages.
    case reconnected
}

/// Why a connection ended, in the only terms the reconnect policy cares about.
public nonisolated enum MailEventChannelError: Error, Sendable, Hashable {
    /// 401 at the upgrade. The token is stale (or dead): refresh and retry once.
    case unauthorized
    /// Any other non-101 answer — 403 (scope/origin), 426, 429, 503
    /// (`EVENT_SERVICE_UNAVAILABLE`), a proxy's 502.
    case rejected(status: Int)
    /// The server closed an established socket. `1008` is what the lease end
    /// looks like ("Reconnect to renew authentication."), and also what a fourth
    /// connection for the same user does to the oldest one.
    case closed(code: Int?)
    /// Anything below HTTP: DNS, TLS, a dropped TCP connection.
    case transport(String)
}

/// One live connection. Deliberately dumb — it hands back raw text frames and
/// knows nothing about topics — so the frame contract is tested in one place.
public nonisolated protocol MailEventChannel: Sendable {
    /// The next text frame. Throws ``MailEventChannelError`` when the connection
    /// ends; it never returns to signal a close.
    ///
    /// A pending `receive()` is unblocked ONLY by ``close()`` — never by
    /// cancelling the task that is awaiting it. The production channel is
    /// `URLSessionWebSocketTask.receive()`, a bridged completion-handler call
    /// that does not observe Task cancellation, so every caller (the watchdog
    /// included) has to close the channel to get out. A conforming fake must
    /// keep that contract, or it hides the bug instead of catching it.
    func receive() async throws -> String
    /// Tears the connection down, failing any pending ``receive()``. Idempotent,
    /// and safe to call from anywhere.
    func close()
}

/// Opens connections. The seam tests inject a fake through.
public nonisolated protocol MailEventChannelOpening: Sendable {
    /// Performs the upgrade with `token` as the bearer credential, returning only
    /// once the socket is established (or throwing ``MailEventChannelError``).
    func open(token: String) async throws -> any MailEventChannel
}

/// The wake socket: `GET /api/v1/events`, reconnected forever, translated into
/// ``MailEventSignal``s.
///
/// It is a WAKE, not a delivery channel. The server states the frames carry no
/// payload and are not replayed, and the connection is a ten-minute lease that
/// the server closes — so this type never tries to be reliable. It only shortens
/// the latency between "the server changed" and "Herald asks". The poll loop in
/// ``SyncEngine`` stays, stretched while this socket is healthy and back at full
/// cadence the moment it is not, which is what makes a permanently failing
/// socket a non-event.
///
/// An actor because the reconnect state (failure count, current channel) is
/// mutated from the loop and read by `stop()`; the loop's sleeps are therefore
/// never on the main actor.
public actor MailEventSocket {
    /// First reconnect delay after a failure, doubled per consecutive failure.
    public static let defaultBaseBackoff: Duration = .seconds(2)
    /// Ceiling on that doubling. A socket that cannot connect must not stop
    /// trying — polling is carrying the app meanwhile — but must not hammer.
    public static let defaultMaxBackoff: Duration = .seconds(120)
    /// How long a connection has to last before its end counts as "it did its
    /// job" rather than a failure. The lease is ten minutes, so anything past
    /// this is a lease end (or a genuine idle close) and reconnects promptly
    /// instead of backing off.
    public static let defaultHealthyConnectionDuration: Duration = .seconds(60)
    /// Silence after which the socket is presumed dead and rebuilt.
    ///
    /// A half-open TCP connection (lid closed, network switched) leaves
    /// `receive()` parked forever with no close and no error — and a socket the
    /// client still believes in is a socket that keeps the poll loop stretched.
    /// The server closes at ten minutes, so silence past this is not normal.
    public static let defaultReceiveTimeout: Duration = .seconds(11 * 60)

    private let channels: any MailEventChannelOpening
    private let tokens: any BearerTokenProvider
    /// All three callbacks are ASYNC and awaited from inside the actor, so they
    /// are delivered in the order the socket produced them. Firing them into
    /// detached tasks reorders them, and a reordered health pair is a poll left
    /// stretched behind a dead socket.
    private let signal: @Sendable (MailEventSignal) async -> Void
    private let healthChanged: @Sendable (Bool) async -> Void
    private let reauthenticationRequired: @Sendable () async -> Void

    private let baseBackoff: Duration
    private let maxBackoff: Duration
    private let healthyConnectionDuration: Duration
    private let receiveTimeout: Duration
    /// Injected so tests run the backoff ladder without waiting it out.
    private let sleep: @Sendable (Duration) async throws -> Void
    /// The receive watchdog's wait. A SEPARATE seam from ``sleep`` on purpose: a
    /// test that collapses the backoff to nothing must not also collapse the
    /// eleven-minute watchdog, or every connection dies the instant it opens.
    private let watchdogSleep: @Sendable (Duration) async throws -> Void
    /// Injected so tests get a deterministic ladder. Returns a factor in `0...1`.
    private let jitter: @Sendable () -> Double
    /// Injected so "how long was this connection up?" is assertable.
    private let now: @Sendable () -> ContinuousClock.Instant

    private var loopTask: Task<Void, Never>?
    private var channel: (any MailEventChannel)?
    private var consecutiveFailures = 0
    private var isHealthy = false
    /// Bumped by every `start()` and every `stop()`.
    ///
    /// `stop()` suspends on `await task?.value`, which RELEASES the actor — so a
    /// `start()` arriving in that window (a resign-active immediately followed by
    /// a become-active) sees no loop task and launches a second loop. Each run
    /// carries the generation it began under and checks it before touching shared
    /// state, so the outgoing loop can neither clear the incoming one's channel
    /// (orphaning a live socket the server counts against its three-per-user cap)
    /// nor report its health.
    private var runGeneration = 0

    public init(
        channels: any MailEventChannelOpening,
        tokens: any BearerTokenProvider,
        baseBackoff: Duration = MailEventSocket.defaultBaseBackoff,
        maxBackoff: Duration = MailEventSocket.defaultMaxBackoff,
        healthyConnectionDuration: Duration = MailEventSocket.defaultHealthyConnectionDuration,
        receiveTimeout: Duration = MailEventSocket.defaultReceiveTimeout,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        watchdogSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        healthChanged: @escaping @Sendable (Bool) async -> Void = { _ in },
        reauthenticationRequired: @escaping @Sendable () async -> Void = {},
        signal: @escaping @Sendable (MailEventSignal) async -> Void
    ) {
        self.channels = channels
        self.tokens = tokens
        self.baseBackoff = baseBackoff
        self.maxBackoff = maxBackoff
        self.healthyConnectionDuration = healthyConnectionDuration
        self.receiveTimeout = receiveTimeout
        self.sleep = sleep
        self.watchdogSleep = watchdogSleep
        self.jitter = jitter
        self.now = now
        self.healthChanged = healthChanged
        self.reauthenticationRequired = reauthenticationRequired
        self.signal = signal
    }

    // MARK: - Lifecycle

    /// Starts the connect loop. A second call while it is running does nothing —
    /// the socket must never be opened twice for one account (the server keeps
    /// only three connections per user and closes the oldest to make room).
    public func start() {
        // A start that lands while a stop is unwinding must neither be dropped
        // (the socket would stay down until the next app activation) nor start a
        // second loop beside the dying one. It is HANDED to the stop instead.
        guard !isStopping else {
            restartWhenStopped = true
            return
        }
        guard loopTask == nil else { return }
        startLoop()
    }

    private func startLoop() {
        consecutiveFailures = 0
        runGeneration &+= 1
        let generation = runGeneration
        loopTask = Task { [weak self] in
            await self?.runLoop(generation: generation)
        }
    }

    /// Stops the loop and closes the connection. Waits for the loop to unwind, so
    /// a caller that is replacing the socket (account switch, re-auth) cannot end
    /// up with two of them talking to the same server.
    public func stop() async {
        let task = loopTask
        loopTask = nil
        runGeneration &+= 1
        let generation = runGeneration
        isStopping = true
        // Closing BEFORE cancelling is what actually frees a loop parked in
        // `receive()` — cancellation alone does not (see ``MailEventChannel``).
        channel?.close()
        channel = nil
        task?.cancel()
        // Releases the actor: another caller may run here, which is why nothing
        // below assumes the state is still ours.
        await task?.value
        guard generation == runGeneration else { return }
        isStopping = false
        await setHealthy(false)
        // A start that arrived mid-teardown takes effect now, in order.
        if restartWhenStopped {
            restartWhenStopped = false
            startLoop()
        }
    }

    /// Whether a teardown is in flight, and whether a `start()` arrived during it.
    private var isStopping = false
    private var restartWhenStopped = false

    /// Test seam: it is what makes "a start landed INSIDE the teardown window"
    /// assertable without a sleep that a loaded machine can lose.
    var isTearingDown: Bool { isStopping }

    /// Whether a connection is currently established. Test seam, and what the
    /// poll-stretch decision is derived from.
    public var isConnected: Bool { isHealthy }

    // MARK: - Loop

    private func runLoop(generation: Int) async {
        while !Task.isCancelled, generation == runGeneration {
            // Set by `runConnection` the moment the socket is actually up. It is
            // NOT the top of the loop: a connection that spent a minute getting a
            // token or completing a slow handshake and then closed at once would
            // otherwise be scored as a healthy full lease, resetting the backoff
            // and reconnecting almost immediately — a hot loop against exactly
            // the struggling server that produced it.
            connectedAt = nil
            do {
                try await runConnection(generation: generation)
                // `runConnection` only returns by throwing; reaching here means
                // the loop was torn down mid-flight.
                return
            } catch is CancellationError {
                await setHealthy(false, generation: generation)
                return
            } catch let error as MailEventChannelError {
                await setHealthy(false, generation: generation)
                if Task.isCancelled { return }
                guard await handle(error) else { return }
            } catch OAuthError.reauthenticationRequired {
                // The refresh itself came back "this grant is dead". Reconnecting
                // cannot help, and each attempt spends another doomed request.
                await escalate(generation: generation, reason: "cannot refresh its token")
                return
            } catch OAuthError.missingRefreshToken {
                await escalate(generation: generation, reason: "has no refresh token")
                return
            } catch {
                await setHealthy(false, generation: generation)
                if Task.isCancelled { return }
                consecutiveFailures += 1
                logger.warning("Event socket failed: \(error.localizedDescription, privacy: .private)")
            }
            guard !Task.isCancelled, generation == runGeneration else { return }
            do {
                try await sleep(backoffDelay)
            } catch {
                return
            }
        }
    }

    /// When the CURRENT connection came up, or `nil` while none is established.
    private var connectedAt: ContinuousClock.Instant?

    private func escalate(generation: Int, reason: String) async {
        await setHealthy(false, generation: generation)
        logger.warning("Event socket \(reason, privacy: .public); re-authentication required")
        guard generation == runGeneration else { return }
        loopTask = nil
        await reauthenticationRequired()
    }

    /// Opens one connection and pumps it until it ends.
    private func runConnection(generation: Int) async throws {
        let token = try await tokens.accessToken()
        let opened: any MailEventChannel
        do {
            opened = try await channels.open(token: token)
        } catch MailEventChannelError.unauthorized {
            // Exactly the middleware's contract for REST: refresh the token that
            // was actually rejected, retry ONCE, and escalate rather than loop.
            logger.warning("Event socket upgrade rejected (401); refreshing the token once")
            let refreshed = try await tokens.refreshAccessToken(failedToken: token)
            opened = try await channels.open(token: refreshed)
        }
        // Nothing above is interruptible from here, so a teardown that happened
        // while the handshake was in flight is only observable NOW. Reporting
        // health or asking for a re-read on behalf of a superseded account is
        // how a signed-out graph gets to drive the live one.
        guard !Task.isCancelled, generation == runGeneration else {
            opened.close()
            throw CancellationError()
        }
        channel = opened
        connectedAt = now()
        consecutiveFailures = 0
        // Cleared here rather than at the top of the next iteration so a
        // cancelled loop leaves nothing behind either.
        defer {
            opened.close()
            if generation == runGeneration { channel = nil }
        }
        await setHealthy(true, generation: generation)
        // A gap in the connection is a gap in the frames — nothing is replayed —
        // so a fresh socket always means "re-read everything".
        await signal(.reconnected)

        while true {
            try Task.checkCancellation()
            let text = try await receiveWithTimeout(from: opened)
            guard let topic = Self.topic(inFrame: text) else {
                // An unknown frame is not a failure: the server is allowed to add
                // topics and types, and a client that closed on them would be
                // permanently disconnected by a server upgrade.
                logger.debug("Ignoring unrecognized event frame")
                continue
            }
            await signal(.changed(topic))
        }
    }

    /// `receive()` parked past the point where the server would have closed means
    /// the connection is gone without having said so.
    ///
    /// The watchdog CLOSES the channel rather than merely cancelling the receive
    /// task. `URLSessionWebSocketTask.receive()` does not observe Task
    /// cancellation, so `cancelAll()` alone leaves the child running and the task
    /// group never returns — the watchdog would be dead code on precisely the
    /// half-open connection it exists for, leaving the poll stretched forever
    /// behind a socket that is silently gone.
    private func receiveWithTimeout(from channel: any MailEventChannel) async throws -> String {
        let timeout = receiveTimeout
        let sleep = watchdogSleep
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await channel.receive() }
            group.addTask {
                try await sleep(timeout)
                channel.close()
                throw MailEventChannelError.transport("no frame within the lease window")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw MailEventChannelError.transport("event socket ended without a result")
            }
            return first
        }
    }

    /// Applies the reconnect policy to one ended connection.
    /// - Returns: whether the loop should keep going.
    private func handle(_ error: MailEventChannelError) async -> Bool {
        switch error {
        case .unauthorized:
            // The refresh inside `runConnection` already happened and the retry
            // was rejected too: the grant is dead and only the UI can fix it.
            // Stop, exactly as `SyncEngine` does, rather than hammer a server
            // that will keep saying no.
            logger.warning("Event socket unauthorized after a refresh; re-authentication required")
            loopTask = nil
            await reauthenticationRequired()
            return false
        case .closed(let code):
            // A connection that lasted is one that did its job: the ten-minute
            // lease ending is the NORMAL case, and treating it as a failure would
            // ratchet the backoff up during perfectly healthy operation. Measured
            // from when the socket actually came UP, never from the attempt.
            if let connectedAt, connectedAt.duration(to: now()) >= healthyConnectionDuration {
                consecutiveFailures = 0
                logger.debug("Event socket lease ended (code \(code ?? -1, privacy: .public)); reconnecting")
            } else {
                consecutiveFailures += 1
                logger.warning("Event socket closed early (code \(code ?? -1, privacy: .public))")
            }
            return true
        case .rejected(let status):
            consecutiveFailures += 1
            logger.warning("Event socket rejected (HTTP \(status, privacy: .public)); polling carries the app")
            return true
        case .transport(let reason):
            consecutiveFailures += 1
            logger.warning("Event socket transport failure: \(reason, privacy: .public)")
            return true
        }
    }

    /// Exponential, capped, and jittered — every Herald process reconnects at the
    /// same moment after a server restart otherwise, and the ten-minute lease
    /// means every client's lease ends at a similar time too.
    ///
    /// The jitter is FULL (`0...1` of the delay) rather than a narrow band: it is
    /// what spreads a fleet, and a reconnect that happens early is harmless.
    private var backoffDelay: Duration {
        guard consecutiveFailures > 0 else {
            // A healthy lease end: reconnect at once, with just enough jitter to
            // keep a fleet from stampeding — but never at zero, which would be a
            // hot loop if the server started closing sockets the moment they
            // reached the healthy mark.
            return max(baseBackoff.scaled(by: jitter()), Self.minimumReconnectDelay)
        }
        let multiplier = Double(1 << min(consecutiveFailures - 1, 16))
        let capped = min(baseBackoff.scaled(by: multiplier), maxBackoff)
        // Half the delay is fixed so the backoff still grows monotonically in
        // expectation; the other half is spread.
        return capped.scaled(by: 0.5 + 0.5 * jitter())
    }

    /// The floor under any reconnect delay.
    static let minimumReconnectDelay: Duration = .milliseconds(250)

    /// Reports a health change, in order.
    ///
    /// The callback is AWAITED from inside the actor rather than fired into a
    /// detached `Task`: two unordered tasks can apply a `true`/`false` pair to
    /// the ``SyncEngine`` backwards, and since the engine's flag is a plain latch
    /// the result is an engine that believes a dead socket is alive and stays
    /// stretched to 120s forever — the exact silent-staleness failure the whole
    /// design is built to avoid.
    private func setHealthy(_ healthy: Bool, generation: Int? = nil) async {
        if let generation, generation != runGeneration { return }
        guard healthy != isHealthy else { return }
        isHealthy = healthy
        await healthChanged(healthy)
    }

    // MARK: - Frames

    /// The topic of a `{"type":"changed","topic":"…"}` frame, or `nil` for
    /// anything else.
    nonisolated static func topic(inFrame text: String) -> MailEventTopic? {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONDecoder().decode(Frame.self, from: data),
              frame.type == "changed",
              let topic = frame.topic
        else { return nil }
        return MailEventTopic(rawValue: topic)
    }

    private nonisolated struct Frame: Decodable {
        let type: String
        let topic: String?
    }
}

nonisolated extension Duration {
    /// Scales a duration by a factor, in whole milliseconds (which is all any of
    /// these delays needs, and keeps the arithmetic away from `Int64` overflow).
    func scaled(by factor: Double) -> Duration {
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return .milliseconds(Int64(max(0, milliseconds * factor)))
    }
}
