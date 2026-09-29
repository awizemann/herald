import Foundation
import OSLog

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "Classification")

// MARK: - Seams

/// Picks at most one label for a message. ``EmailClassifier`` conforms; tests fake it.
public nonisolated protocol EmailClassifying: Sendable {
    func classify(_ input: ClassificationInput, candidates: [ClassificationCandidate]) async throws -> ClassificationCandidate?
}

extension EmailClassifier: EmailClassifying {}

/// The cache reads classification needs. ``MailStore`` conforms as-is.
public nonisolated protocol ClassificationStore: Sendable {
    func message(id: String, accountID: String) async throws -> MessageSummary?
    func messages(accountID: String, threadID: String) async throws -> [MessageSummary]
    /// Whether ANY message of the thread carries ANY label in the cache.
    func threadHasLabels(threadID: String, accountID: String) async throws -> Bool
}

extension MailStore: ClassificationStore {}

/// Plain-text body of one message, or `nil` when there is none to be had.
public nonisolated protocol ClassificationBodySource: Sendable {
    func plainText(messageID: String, accountID: String) async throws -> String?
}

/// Applies the chosen label to a whole thread. ``MailActionService`` conforms, so
/// the optimistic cache write, the fence and the revert-on-rejection all apply.
public nonisolated protocol ClassificationLabelApplying: Sendable {
    func applyLabel(_ labelID: String, toThread threadID: String, accountID: String) async throws
}

extension MailActionService: ClassificationLabelApplying {
    public func applyLabel(_ labelID: String, toThread threadID: String, accountID: String) async throws {
        try await setLabel(labelID, onConversation: threadID, accountID: accountID, assigned: true)
    }
}

/// The body path the reading pane already uses: the cached sidecar first, then
/// `GET /messages/{id}`. Never writes the sidecar — a text-only row would stand
/// in for the HTML the reading pane has not fetched yet.
public nonisolated struct CachedOrFetchedBodySource: ClassificationBodySource {
    private let store: MailStore
    private let api: any MailAPIClient

    public init(store: MailStore, api: any MailAPIClient) {
        self.store = store
        self.api = api
    }

    public func plainText(messageID: String, accountID: String) async throws -> String? {
        if let cached = try await store.cachedBody(messageID: messageID, accountID: accountID),
           !cached.textBody.isEmpty {
            return cached.textBody
        }
        return try await api.message(id: messageID).textBody
    }
}

/// The SERVER's view of a thread, read just before a model call. The cache can
/// lack older messages (it only holds what was synced) and can lag label
/// membership, so the "unlabelled" and "first inbound" checks are repeated
/// against this before any money is spent.
public nonisolated protocol ClassificationThreadSource: Sendable {
    /// Every message of the thread `messageID` belongs to. `labels` on each is
    /// `nil` when the server did not say (see ``MessageSummary/labels``).
    func serverThread(messageID: String) async throws -> [MessageSummary]
}

/// `GET /api/v1/messages/{id}/thread`. The app's client sends
/// `includeLabels=true`, so each message carries its label membership.
public nonisolated struct APIThreadSource: ClassificationThreadSource {
    private let api: any MailAPIClient

    public init(api: any MailAPIClient) { self.api = api }

    public func serverThread(messageID: String) async throws -> [MessageSummary] {
        try await api.thread(messageID: messageID).map(\.summary)
    }
}

/// Thread ids already sent to the model, persisted so a relaunch does not
/// re-classify a thread that got "none". Written just before the model call and
/// withdrawn only when that call failed in a retryable way. The app backs it
/// with UserDefaults.
public nonisolated protocol ClassificationAttemptPersisting: Sendable {
    func load() -> [String: Date]
    func save(_ attempts: [String: Date])
}

// MARK: - Values

/// One domain's live rules, resolved by the app for each pass.
public nonisolated struct ClassificationDomainRules: Sendable, Hashable {
    public var candidates: [ClassificationCandidate]
    /// Only mail received at or after this is classified (no backfill).
    public var enabledAt: Date

    public init(candidates: [ClassificationCandidate], enabledAt: Date) {
        self.candidates = candidates
        self.enabledAt = enabledAt
    }
}

/// Everything a pass needs from the app's preferences. The app passes `nil`
/// when the gateway is not configured or no domain has usable rules.
public nonisolated struct ClassificationContext: Sendable, Hashable {
    /// mailbox id → its domain's rules. A mailbox missing here is "domain off".
    public var rulesByMailbox: [String: ClassificationDomainRules]
    public var configuration: AIGatewayConfiguration

    public init(rulesByMailbox: [String: ClassificationDomainRules], configuration: AIGatewayConfiguration) {
        self.rulesByMailbox = rulesByMailbox
        self.configuration = configuration
    }
}

/// Why a message was not sent to the model (or its answer not applied).
public nonisolated enum ClassificationSkipReason: String, Sendable, Hashable, CaseIterable {
    case notInbound
    case notInbox
    case domainOff
    case noRules
    case beforeEnabled
    /// Received longer ago than ``ClassificationEngine/maxMessageAge``: an old
    /// message re-entering the cache (a delete re-delivered by the journal), not
    /// new mail — and possibly one whose "none" the attempt log has forgotten.
    case tooOld
    case alreadyAttempted
    case threadLabelled
    case notFirstInbound
    case hourlyCap
    /// The thread gained a label while the model was answering.
    case labelledMeanwhile
    case paused

    /// Reasons that say nothing about classification to a user reading the
    /// activity log (every outbound message, every other domain) — not recorded.
    public var isSilent: Bool {
        switch self {
        case .notInbound, .notInbox, .domainOff, .noRules, .alreadyAttempted, .tooOld: true
        default: false
        }
    }
}

public nonisolated enum ClassificationOutcome: Sendable, Hashable {
    case labelled(labelID: String, labelName: String)
    /// The model answered none (or a tag that is not a candidate); nothing written.
    case none
    case skipped(ClassificationSkipReason)
    /// A per-message or gateway failure. `reason` is a short code — never a body,
    /// never a token.
    case failed(reason: String)
}

/// One decision, for the Workflows page's activity log.
public nonisolated struct ClassificationRecord: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let date: Date
    public let threadID: String
    public let messageID: String
    /// Which mailbox the message arrived in — the page filters by domain on it.
    public let mailboxID: String?
    public let subject: String
    /// The provider-prefixed model, or `nil` when no model was involved.
    public let model: String?
    public let outcome: ClassificationOutcome

    public init(
        id: UUID = UUID(), date: Date, threadID: String, messageID: String, mailboxID: String? = nil,
        subject: String, model: String?, outcome: ClassificationOutcome
    ) {
        self.id = id
        self.date = date
        self.threadID = threadID
        self.messageID = messageID
        self.mailboxID = mailboxID
        self.subject = subject
        self.model = model
        self.outcome = outcome
    }
}

/// The activity log at one moment. `version` only grows, so an observer that
/// receives two snapshots out of order keeps the newer.
public nonisolated struct ClassificationActivitySnapshot: Sendable, Hashable {
    public let version: Int
    public let records: [ClassificationRecord]

    public init(version: Int, records: [ClassificationRecord]) {
        self.version = version
        self.records = records
    }
}

public nonisolated enum ClassificationEligibility: Sendable, Hashable {
    case eligible(ClassificationDomainRules)
    case skip(ClassificationSkipReason)
}

// MARK: - Engine

/// Classifies the first inbound message of each new, unlabelled thread, and
/// labels the thread with the model's pick.
///
/// Same split as ``NewMailNotifier``: pure static rules, and an actor that does
/// the effectful half. ``handle(_:accountID:context:)`` only DECIDES and queues —
/// it is called from the sync event loop and must not hold it for a model
/// round trip — and a single drain task works the queue one message at a time.
public actor ClassificationEngine {
    public static let defaultHourlyLimit = 60
    static let memoLimit = 1_000
    static let activityLimit = 200
    static let persistedLimit = 500
    static let persistedLifetime: TimeInterval = 7 * 24 * 3600
    /// Cap on store lookups per pass, like the notifier's.
    static let maxLookups = 100
    /// Jobs waiting (queued, or held by a pause, the hourly cap or a backoff).
    /// Past this the oldest is dropped.
    static let pendingLimit = 100
    /// A job that failed transiently this many times is dropped (not persisted).
    static let maxTransientFailures = 3
    /// Backoff after a 429 or a transient failure: doubles, reset by an answer.
    static let initialBackoff: TimeInterval = 60
    static let maxBackoff: TimeInterval = 15 * 60
    /// Only mail received this recently is classified. Shorter than
    /// ``persistedLifetime``, so any thread attempted for such a message is
    /// still in the attempt log.
    public static let maxMessageAge: TimeInterval = 6 * 24 * 3600

    private struct Job: Sendable {
        let message: MessageSummary
        let rules: ClassificationDomainRules
        var failures = 0
    }

    /// What became of one job.
    private enum Disposition {
        case done
        /// Keep it at the head of the queue; the drain stops until the gate opens.
        case hold
        /// Failed transiently: back off, then retry it.
        case retry
    }

    private let store: any ClassificationStore
    private let bodies: any ClassificationBodySource
    private let labeler: any ClassificationLabelApplying
    private let serverThreads: (any ClassificationThreadSource)?
    private let makeClassifier: @Sendable (AIGatewayConfiguration) -> any EmailClassifying
    private let attemptLog: (any ClassificationAttemptPersisting)?
    private let hourlyLimit: Int
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var queue: [Job] = []
    private var drainTask: Task<Void, Never>?
    /// Re-starts the drain when the hourly window frees up or a backoff ends.
    private var wakeTask: Task<Void, Never>?
    private var callTimes: [Date] = []
    /// Set by ``stop()`` and never cleared: nothing may start or write after it.
    private var stopped = false
    private var accountID: String?
    private var retryAfter: Date?
    private var backoff: TimeInterval = 0

    /// Threads queued, in flight or done this session. Bounded.
    private var attempted: Set<String> = []
    private var attemptedOrder: [String] = []
    /// The persisted half: thread id → when it was attempted.
    private var persisted: [String: Date]

    private var records: [ClassificationRecord] = []
    /// Set by a gateway-level failure; nothing is classified while it is.
    public private(set) var pauseReason: AIGatewayError?
    private var pausedConfiguration: AIGatewayConfiguration?
    /// The newest pass's gateway settings. Jobs use it rather than the one they
    /// were queued under, so a fixed configuration applies to work already queued.
    private var configuration: AIGatewayConfiguration?

    private var onApplied: (@Sendable (String) async -> Void)?
    private var onPauseChanged: (@Sendable (AIGatewayError?) async -> Void)?
    private var onActivityChanged: (@Sendable (ClassificationActivitySnapshot) async -> Void)?
    /// Bumped on every record, so an observer can drop a snapshot that lost a
    /// race to a newer one.
    private var activityVersion = 0

    public init(
        store: any ClassificationStore,
        bodies: any ClassificationBodySource,
        labeler: any ClassificationLabelApplying,
        serverThreads: (any ClassificationThreadSource)? = nil,
        makeClassifier: @escaping @Sendable (AIGatewayConfiguration) -> any EmailClassifying,
        attemptLog: (any ClassificationAttemptPersisting)? = nil,
        hourlyLimit: Int = ClassificationEngine.defaultHourlyLimit,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.store = store
        self.bodies = bodies
        self.labeler = labeler
        self.serverThreads = serverThreads
        self.makeClassifier = makeClassifier
        self.attemptLog = attemptLog
        self.hourlyLimit = hourlyLimit
        self.now = now
        self.sleep = sleep
        self.persisted = attemptLog?.load() ?? [:]
    }

    /// `onApplied` gets the thread id after a label was written (the view-model
    /// refreshes its chips); `onPauseChanged` fires on each TRANSITION into or
    /// out of a gateway-level pause — once, not per message; `onActivityChanged`
    /// gets the whole (bounded) log after every new record.
    public func setObservers(
        onApplied: (@Sendable (String) async -> Void)?,
        onPauseChanged: (@Sendable (AIGatewayError?) async -> Void)?,
        onActivityChanged: (@Sendable (ClassificationActivitySnapshot) async -> Void)? = nil
    ) async {
        self.onApplied = onApplied
        self.onPauseChanged = onPauseChanged
        self.onActivityChanged = onActivityChanged
        // A pause or a record that happened before anyone was listening is still news.
        if let pauseReason { await onPauseChanged?(pauseReason) }
        if !records.isEmpty { await onActivityChanged?(ClassificationActivitySnapshot(version: activityVersion, records: records)) }
    }

    /// Recent decisions, oldest first (at most ``activityLimit``).
    public var activity: [ClassificationRecord] { records }

    /// Clears a pause by hand (e.g. after the token was replaced) and works the
    /// jobs the pause held.
    public func resume() async {
        guard pauseReason != nil else { return }
        pauseReason = nil
        pausedConfiguration = nil
        await onPauseChanged?(nil)
        startDrainIfNeeded()
    }

    /// Drops queued work and stops the drain for good — account teardown. Awaits
    /// the message in flight (its request is cancelled with the task), and the
    /// `stopped` flag stops a `handle` suspended in a store read from queueing
    /// behind this, so no label write can land after a sign-out purge.
    public func stop() async {
        stopped = true
        queue.removeAll()
        wakeTask?.cancel()
        wakeTask = nil
        drainTask?.cancel()
        await drainTask?.value
    }

    /// Resolves once nothing is draining or scheduled to. Tests await this
    /// instead of sleeping (their sleeper advances a fake clock).
    public func waitUntilIdle() async {
        while true {
            if let task = drainTask { await task.value; continue }
            if let task = wakeTask { await task.value; continue }
            return
        }
    }

    // MARK: Rules (pure)

    /// The checks one message can answer on its own.
    public nonisolated static func messageEligibility(
        _ message: MessageSummary,
        rulesByMailbox: [String: ClassificationDomainRules],
        alreadyAttempted: Bool,
        now: Date? = nil
    ) -> ClassificationEligibility {
        guard message.direction == .inbound else { return .skip(.notInbound) }
        guard message.folder == .inbox else { return .skip(.notInbox) }
        guard let mailboxID = message.mailboxID, let rules = rulesByMailbox[mailboxID] else { return .skip(.domainOff) }
        guard !rules.candidates.isEmpty else { return .skip(.noRules) }
        let received = message.receivedAt ?? message.createdAt
        guard received >= rules.enabledAt else { return .skip(.beforeEnabled) }
        if let now, now.timeIntervalSince(received) > maxMessageAge { return .skip(.tooOld) }
        guard !alreadyAttempted else { return .skip(.alreadyAttempted) }
        return .eligible(rules)
    }

    /// The full rule set: the message's own checks, then its thread's.
    public nonisolated static func eligibility(
        of message: MessageSummary,
        rulesByMailbox: [String: ClassificationDomainRules],
        alreadyAttempted: Bool,
        threadHasLabels: Bool,
        threadMessages: [MessageSummary],
        now: Date? = nil
    ) -> ClassificationEligibility {
        let own = messageEligibility(message, rulesByMailbox: rulesByMailbox, alreadyAttempted: alreadyAttempted, now: now)
        guard case .eligible = own else { return own }
        guard !threadHasLabels else { return .skip(.threadLabelled) }
        guard isFirstInbound(message, in: threadMessages) else { return .skip(.notFirstInbound) }
        return own
    }

    /// No OTHER inbound message of the thread is earlier (ties broken by id, so
    /// two arrivals with the same timestamp still elect exactly one).
    public nonisolated static func isFirstInbound(_ message: MessageSummary, in thread: [MessageSummary]) -> Bool {
        let date = message.displayDate
        return !thread.contains { other in
            other.id != message.id && other.direction == .inbound
                && (other.displayDate < date || (other.displayDate == date && other.id < message.id))
        }
    }

    /// The server-side re-check: any label on any message of the thread, or an
    /// earlier inbound message the cache never held.
    public nonisolated static func serverSkipReason(for message: MessageSummary, thread: [MessageSummary]) -> ClassificationSkipReason? {
        if serverThreadHasLabels(thread) { return .threadLabelled }
        guard isFirstInbound(message, in: thread) else { return .notFirstInbound }
        return nil
    }

    /// Any label on any message of the server's thread. `labels == nil` means
    /// the server did not say (a server older than the 1.4.2 label embed; the
    /// minimum supported server is 1.3.4, so it can happen) and deliberately
    /// counts as UNLABELLED — otherwise such a server could never be classified.
    /// The cache checks before the queue and before the write still stand.
    public nonisolated static func serverThreadHasLabels(_ thread: [MessageSummary]) -> Bool {
        thread.contains { !($0.labels ?? []).isEmpty }
    }

    /// Worth retrying after a backoff: the gateway was busy or unreachable.
    public nonisolated static func isTransient(_ error: AIGatewayError) -> Bool {
        switch error {
        case .rateLimited, .transport: true
        case .http(let status): status >= 500
        default: false
        }
    }

    public nonisolated static func isGatewayLevel(_ error: AIGatewayError) -> Bool {
        switch error {
        case .unauthorized, .insufficientCredits, .modelNotAllowed, .blocked, .missingToken, .invalidConfiguration:
            true
        case .rateLimited, .http, .malformedResponse, .transport:
            false
        }
    }

    /// A log- and record-safe name for an error: no URL, host or payload.
    public nonisolated static func code(for error: AIGatewayError) -> String {
        switch error {
        case .http(let status): "http\(status)"
        case .transport: "transport"
        default: String(describing: error)
        }
    }

    // MARK: Driving

    /// Called for every `.changed` event. Decides and queues; never waits for a model.
    public func handle(_ changes: ChangeSet, accountID: String, context: ClassificationContext?) async {
        // No backfill: a bootstrap lists the whole mailbox as inserted.
        guard !stopped, let context, !changes.isBootstrap, !changes.inserted.isEmpty else { return }
        self.accountID = accountID
        configuration = context.configuration
        // A changed configuration is the user acting on the pause. Otherwise new
        // mail still queues behind the pause and is worked on resume.
        if pauseReason != nil, context.configuration != pausedConfiguration {
            await resume()
            guard !stopped else { return }
        }
        let ids = changes.inserted.sorted().prefix(Self.maxLookups)
        for id in ids {
            let message: MessageSummary?
            do {
                message = try await store.message(id: id, accountID: accountID)
            } catch {
                logger.warning("Classification lookup failed: \(error.localizedDescription, privacy: .private)")
                continue
            }
            guard !stopped else { return }
            guard let message else { continue }
            let own = Self.messageEligibility(
                message, rulesByMailbox: context.rulesByMailbox, alreadyAttempted: isAttempted(message.threadID), now: now()
            )
            if case .skip(let reason) = own {
                if !reason.isSilent { await record(message, model: nil, .skipped(reason)) }
                continue
            }

            let verdict: ClassificationEligibility
            do {
                let hasLabels = try await store.threadHasLabels(threadID: message.threadID, accountID: accountID)
                guard !stopped else { return }
                let thread = try await store.messages(accountID: accountID, threadID: message.threadID)
                guard !stopped else { return }
                verdict = Self.eligibility(
                    of: message, rulesByMailbox: context.rulesByMailbox,
                    // Re-read AFTER the awaits: an interleaved pass may have queued it.
                    alreadyAttempted: isAttempted(message.threadID),
                    threadHasLabels: hasLabels, threadMessages: thread, now: now()
                )
            } catch {
                logger.warning("Classification thread lookup failed: \(error.localizedDescription, privacy: .private)")
                continue
            }
            switch verdict {
            case .skip(let reason):
                if !reason.isSilent { await record(message, model: nil, .skipped(reason)) }
            case .eligible(let rules):
                // Claimed synchronously with the check: no await between them.
                remember(message.threadID)
                queue.append(Job(message: message, rules: rules))
                if queue.count > Self.pendingLimit {
                    let dropped = queue.removeFirst()
                    forget(dropped.message.threadID)
                    logger.warning("Classification queue full; dropping the oldest job")
                }
            }
        }
        startDrainIfNeeded()
    }

    private func startDrainIfNeeded() {
        guard !stopped, drainTask == nil, let accountID, !queue.isEmpty else { return }
        drainTask = Task { [weak self] in
            await self?.drain(accountID: accountID)
        }
    }

    /// Works the queue one job at a time until it is empty or a gate (pause,
    /// hourly cap, backoff) closes. A closed gate leaves the jobs queued: a pause
    /// re-drains on resume, the cap and the backoff on a scheduled wake.
    private func drain(accountID: String) async {
        while !queue.isEmpty, !Task.isCancelled, !stopped, gateIsOpen() {
            let job = queue.removeFirst()
            switch await process(job, accountID: accountID) {
            case .done:
                break
            case .hold:
                if !stopped { queue.insert(job, at: 0) }
            case .retry:
                var retried = job
                retried.failures += 1
                if retried.failures >= Self.maxTransientFailures {
                    // Not persisted: a later insert for the thread may try again.
                    forget(job.message.threadID)
                    logger.warning("Classification gave up on a message after repeated failures")
                } else if !stopped {
                    queue.insert(retried, at: 0)
                }
                startBackoff()
            }
        }
        drainTask = nil
    }

    /// Whether the next job may run now; schedules the wake when it may not.
    private func gateIsOpen() -> Bool {
        guard pauseReason == nil else { return false }   // resume() re-drains
        let current = now()
        if let retryAfter, retryAfter > current {
            scheduleWake(after: retryAfter.timeIntervalSince(current))
            return false
        }
        callTimes.removeAll { current.timeIntervalSince($0) >= 3600 }
        if callTimes.count >= hourlyLimit, let oldest = callTimes.first {
            logger.info("Classification hourly cap (\(self.hourlyLimit, privacy: .public)) reached; holding \(self.queue.count, privacy: .public) job(s)")
            scheduleWake(after: 3600 - current.timeIntervalSince(oldest))
            return false
        }
        return true
    }

    private func startBackoff() {
        backoff = backoff == 0 ? Self.initialBackoff : min(backoff * 2, Self.maxBackoff)
        retryAfter = now().addingTimeInterval(backoff)
    }

    private func scheduleWake(after seconds: TimeInterval) {
        guard !stopped, wakeTask == nil else { return }
        let sleep = self.sleep
        wakeTask = Task { [weak self] in
            let slept = (try? await sleep(max(seconds, 0))) != nil
            await self?.woke(slept: slept)
        }
    }

    private func woke(slept: Bool) {
        wakeTask = nil
        guard slept else { return }
        startDrainIfNeeded()
    }

    private func process(_ job: Job, accountID: String) async -> Disposition {
        let message = job.message
        guard let configuration else { return .done }
        let model = configuration.model

        // The server's thread, not the cache's, decides — BEFORE the call that
        // costs money. A failed read is retried after a backoff.
        if let serverThreads {
            do {
                let thread = try await serverThreads.serverThread(messageID: message.id)
                if let reason = Self.serverSkipReason(for: message, thread: thread) {
                    persistAttempt(message.threadID)
                    await record(message, model: nil, .skipped(reason))
                    return .done
                }
            } catch {
                logger.warning("Classification thread check failed: \(error.localizedDescription, privacy: .private)")
                await record(message, model: nil, .failed(reason: "threadCheck"))
                return .retry
            }
            guard !Task.isCancelled, !stopped else { return .done }
        }

        let body: String
        do {
            let text = try await bodies.plainText(messageID: message.id, accountID: accountID)
            body = (text?.isEmpty == false ? text : nil) ?? message.snippet
        } catch {
            logger.info("Classification body fetch failed; using the snippet")
            body = message.snippet
        }
        guard !Task.isCancelled, !stopped else { return .done }

        callTimes.append(now())
        // Persisted BEFORE the call, so a crash mid-call counts as attempted
        // (fewer tags is the safe direction); withdrawn only when the call
        // failed in a way that is retried.
        persistAttempt(message.threadID)
        let choice: ClassificationCandidate?
        do {
            choice = try await makeClassifier(configuration).classify(
                ClassificationInput(from: message.fromAddress, subject: message.subject, body: body),
                candidates: job.rules.candidates
            )
        } catch let error as AIGatewayError {
            logger.warning("Classification request failed: \(Self.code(for: error), privacy: .public)")
            await record(message, model: model, .failed(reason: Self.code(for: error)))
            if Self.isGatewayLevel(error) {
                unpersistAttempt(message.threadID)
                await pause(error, configuration: configuration)
                return .hold
            }
            if Self.isTransient(error) {
                unpersistAttempt(message.threadID)
                return .retry
            }
            return .done
        } catch {
            logger.warning("Classification request failed: \(error.localizedDescription, privacy: .private)")
            await record(message, model: model, .failed(reason: "unknown"))
            return .done
        }
        backoff = 0
        retryAfter = nil
        guard let choice else {
            await record(message, model: model, .none)
            return .done
        }
        guard !Task.isCancelled, !stopped else { return .done }

        // The user (or another device, or the label sweep) may have tagged the
        // thread while the model was answering: theirs wins. The cache first,
        // then the server, which sees another device's label before a sync does.
        do {
            if try await store.threadHasLabels(threadID: message.threadID, accountID: accountID) {
                await record(message, model: model, .skipped(.labelledMeanwhile))
                return .done
            }
            if let serverThreads {
                let thread: [MessageSummary]
                do {
                    thread = try await serverThreads.serverThread(messageID: message.id)
                } catch {
                    logger.warning("Classification pre-write thread check failed: \(error.localizedDescription, privacy: .private)")
                    await record(message, model: model, .failed(reason: "threadCheck"))
                    return .done
                }
                if Self.serverThreadHasLabels(thread) {
                    await record(message, model: model, .skipped(.labelledMeanwhile))
                    return .done
                }
            }
            guard !Task.isCancelled, !stopped else { return .done }
            try await labeler.applyLabel(choice.id, toThread: message.threadID, accountID: accountID)
        } catch {
            logger.warning("Classification label write failed: \(error.localizedDescription, privacy: .private)")
            await record(message, model: model, .failed(reason: "labelWrite"))
            return .done
        }
        await record(message, model: model, .labelled(labelID: choice.id, labelName: choice.name))
        await onApplied?(message.threadID)
        return .done
    }

    private func pause(_ error: AIGatewayError, configuration: AIGatewayConfiguration) async {
        guard pauseReason == nil else { return }
        pauseReason = error
        pausedConfiguration = configuration
        logger.error("Classification paused: \(Self.code(for: error), privacy: .public)")
        await onPauseChanged?(error)
    }

    // MARK: Memo & activity

    private func isAttempted(_ threadID: String) -> Bool {
        attempted.contains(threadID) || persisted[threadID] != nil
    }

    private func remember(_ threadID: String) {
        guard attempted.insert(threadID).inserted else { return }
        attemptedOrder.append(threadID)
        guard attemptedOrder.count > Self.memoLimit else { return }
        attempted.remove(attemptedOrder.removeFirst())
    }

    /// A job dropped without an answer: a later insert for the thread may queue it again.
    private func forget(_ threadID: String) {
        guard attempted.remove(threadID) != nil else { return }
        attemptedOrder.removeAll { $0 == threadID }
    }

    private func unpersistAttempt(_ threadID: String) {
        guard let attemptLog, persisted.removeValue(forKey: threadID) != nil else { return }
        attemptLog.save(persisted)
    }

    private func persistAttempt(_ threadID: String) {
        guard let attemptLog else { return }
        let current = now()
        persisted[threadID] = current
        persisted = persisted.filter { current.timeIntervalSince($0.value) < Self.persistedLifetime }
        if persisted.count > Self.persistedLimit {
            let keep = persisted.sorted { $0.value > $1.value }.prefix(Self.persistedLimit)
            persisted = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        attemptLog.save(persisted)
    }

    private func record(_ message: MessageSummary, model: String?, _ outcome: ClassificationOutcome) async {
        records.append(ClassificationRecord(
            date: now(), threadID: message.threadID, messageID: message.id, mailboxID: message.mailboxID,
            subject: message.subject, model: model, outcome: outcome
        ))
        if records.count > Self.activityLimit { records.removeFirst(records.count - Self.activityLimit) }
        activityVersion += 1
        await onActivityChanged?(ClassificationActivitySnapshot(version: activityVersion, records: records))
    }
}
