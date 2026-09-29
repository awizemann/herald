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

/// Thread ids already sent to the model, persisted so a relaunch does not
/// re-classify a thread that got "none". The app backs it with UserDefaults.
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
        case .notInbound, .notInbox, .domainOff, .noRules, .alreadyAttempted: true
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

/// One decision, for WF5's activity log.
public nonisolated struct ClassificationRecord: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let date: Date
    public let threadID: String
    public let messageID: String
    public let subject: String
    /// The provider-prefixed model, or `nil` when no model was involved.
    public let model: String?
    public let outcome: ClassificationOutcome

    public init(
        id: UUID = UUID(), date: Date, threadID: String, messageID: String,
        subject: String, model: String?, outcome: ClassificationOutcome
    ) {
        self.id = id
        self.date = date
        self.threadID = threadID
        self.messageID = messageID
        self.subject = subject
        self.model = model
        self.outcome = outcome
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

    private struct Job: Sendable {
        let message: MessageSummary
        let rules: ClassificationDomainRules
    }

    private let store: any ClassificationStore
    private let bodies: any ClassificationBodySource
    private let labeler: any ClassificationLabelApplying
    private let makeClassifier: @Sendable (AIGatewayConfiguration) -> any EmailClassifying
    private let attemptLog: (any ClassificationAttemptPersisting)?
    private let hourlyLimit: Int
    private let now: @Sendable () -> Date

    private var queue: [Job] = []
    private var drainTask: Task<Void, Never>?
    private var callTimes: [Date] = []

    /// Threads already sent to the model (or queued for it). Bounded.
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

    public init(
        store: any ClassificationStore,
        bodies: any ClassificationBodySource,
        labeler: any ClassificationLabelApplying,
        makeClassifier: @escaping @Sendable (AIGatewayConfiguration) -> any EmailClassifying,
        attemptLog: (any ClassificationAttemptPersisting)? = nil,
        hourlyLimit: Int = ClassificationEngine.defaultHourlyLimit,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.bodies = bodies
        self.labeler = labeler
        self.makeClassifier = makeClassifier
        self.attemptLog = attemptLog
        self.hourlyLimit = hourlyLimit
        self.now = now
        self.persisted = attemptLog?.load() ?? [:]
    }

    /// `onApplied` gets the thread id after a label was written (the view-model
    /// refreshes its chips); `onPauseChanged` fires on each TRANSITION into or
    /// out of a gateway-level pause — once, not per message.
    public func setObservers(
        onApplied: (@Sendable (String) async -> Void)?,
        onPauseChanged: (@Sendable (AIGatewayError?) async -> Void)?
    ) async {
        self.onApplied = onApplied
        self.onPauseChanged = onPauseChanged
        // A pause that happened before anyone was listening is still news.
        if let pauseReason { await onPauseChanged?(pauseReason) }
    }

    /// Recent decisions, oldest first (at most ``activityLimit``).
    public var activity: [ClassificationRecord] { records }

    /// Clears a pause by hand (e.g. after the token was replaced).
    public func resume() async {
        guard pauseReason != nil else { return }
        pauseReason = nil
        pausedConfiguration = nil
        await onPauseChanged?(nil)
    }

    /// Drops queued work and stops the drain — account teardown. Awaits the
    /// message in flight (its request is cancelled with the task) so no label
    /// write can land behind a sign-out purge.
    public func stop() async {
        queue.removeAll()
        drainTask?.cancel()
        await drainTask?.value
    }

    /// Resolves once the queue is empty. Tests await this instead of sleeping.
    public func waitUntilIdle() async {
        while let task = drainTask { await task.value }
    }

    // MARK: Rules (pure)

    /// The checks one message can answer on its own.
    public nonisolated static func messageEligibility(
        _ message: MessageSummary,
        rulesByMailbox: [String: ClassificationDomainRules],
        alreadyAttempted: Bool
    ) -> ClassificationEligibility {
        guard message.direction == .inbound else { return .skip(.notInbound) }
        guard message.folder == .inbox else { return .skip(.notInbox) }
        guard let mailboxID = message.mailboxID, let rules = rulesByMailbox[mailboxID] else { return .skip(.domainOff) }
        guard !rules.candidates.isEmpty else { return .skip(.noRules) }
        guard (message.receivedAt ?? message.createdAt) >= rules.enabledAt else { return .skip(.beforeEnabled) }
        guard !alreadyAttempted else { return .skip(.alreadyAttempted) }
        return .eligible(rules)
    }

    /// The full rule set: the message's own checks, then its thread's.
    public nonisolated static func eligibility(
        of message: MessageSummary,
        rulesByMailbox: [String: ClassificationDomainRules],
        alreadyAttempted: Bool,
        threadHasLabels: Bool,
        threadMessages: [MessageSummary]
    ) -> ClassificationEligibility {
        let own = messageEligibility(message, rulesByMailbox: rulesByMailbox, alreadyAttempted: alreadyAttempted)
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
        guard let context, !changes.isBootstrap, !changes.inserted.isEmpty else { return }
        configuration = context.configuration
        if pauseReason != nil {
            // A changed configuration is the user acting on the pause.
            guard context.configuration != pausedConfiguration else { return }
            await resume()
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
            guard let message else { continue }
            let own = Self.messageEligibility(
                message, rulesByMailbox: context.rulesByMailbox, alreadyAttempted: isAttempted(message.threadID)
            )
            if case .skip(let reason) = own {
                if !reason.isSilent { record(message, model: nil, .skipped(reason)) }
                continue
            }

            let verdict: ClassificationEligibility
            do {
                let hasLabels = try await store.threadHasLabels(threadID: message.threadID, accountID: accountID)
                let thread = try await store.messages(accountID: accountID, threadID: message.threadID)
                verdict = Self.eligibility(
                    of: message, rulesByMailbox: context.rulesByMailbox,
                    // Re-read AFTER the awaits: an interleaved pass may have queued it.
                    alreadyAttempted: isAttempted(message.threadID),
                    threadHasLabels: hasLabels, threadMessages: thread
                )
            } catch {
                logger.warning("Classification thread lookup failed: \(error.localizedDescription, privacy: .private)")
                continue
            }
            switch verdict {
            case .skip(let reason):
                if !reason.isSilent { record(message, model: nil, .skipped(reason)) }
            case .eligible(let rules):
                // Claimed synchronously with the check: no await between them.
                remember(message.threadID)
                queue.append(Job(message: message, rules: rules))
            }
        }
        startDrainIfNeeded(accountID: accountID)
    }

    private func startDrainIfNeeded(accountID: String) {
        guard drainTask == nil, !queue.isEmpty else { return }
        drainTask = Task { [weak self] in
            await self?.drain(accountID: accountID)
        }
    }

    private func drain(accountID: String) async {
        while !queue.isEmpty, !Task.isCancelled {
            let job = queue.removeFirst()
            await process(job, accountID: accountID)
        }
        drainTask = nil
    }

    private func process(_ job: Job, accountID: String) async {
        let message = job.message
        guard let configuration else { return }
        let model = configuration.model
        guard pauseReason == nil else {
            record(message, model: nil, .skipped(.paused))
            return
        }
        let current = now()
        callTimes.removeAll { current.timeIntervalSince($0) >= 3600 }
        guard callTimes.count < hourlyLimit else {
            logger.info("Classification hourly cap (\(self.hourlyLimit, privacy: .public)) reached; skipping a message")
            record(message, model: nil, .skipped(.hourlyCap))
            return
        }

        let body: String
        do {
            let text = try await bodies.plainText(messageID: message.id, accountID: accountID)
            body = (text?.isEmpty == false ? text : nil) ?? message.snippet
        } catch {
            logger.info("Classification body fetch failed; using the snippet")
            body = message.snippet
        }
        guard !Task.isCancelled else { return }

        callTimes.append(now())
        persistAttempt(message.threadID)
        let choice: ClassificationCandidate?
        do {
            choice = try await makeClassifier(configuration).classify(
                ClassificationInput(from: message.fromAddress, subject: message.subject, body: body),
                candidates: job.rules.candidates
            )
        } catch let error as AIGatewayError {
            logger.warning("Classification request failed: \(Self.code(for: error), privacy: .public)")
            record(message, model: model, .failed(reason: Self.code(for: error)))
            if Self.isGatewayLevel(error) { await pause(error, configuration: configuration) }
            return
        } catch {
            logger.warning("Classification request failed: \(error.localizedDescription, privacy: .private)")
            record(message, model: model, .failed(reason: "unknown"))
            return
        }
        guard let choice else {
            record(message, model: model, .none)
            return
        }
        guard !Task.isCancelled else { return }

        // The user (or another device, or the label sweep) may have tagged the
        // thread while the model was answering: theirs wins.
        do {
            if try await store.threadHasLabels(threadID: message.threadID, accountID: accountID) {
                record(message, model: model, .skipped(.labelledMeanwhile))
                return
            }
            try await labeler.applyLabel(choice.id, toThread: message.threadID, accountID: accountID)
        } catch {
            logger.warning("Classification label write failed: \(error.localizedDescription, privacy: .private)")
            record(message, model: model, .failed(reason: "labelWrite"))
            return
        }
        record(message, model: model, .labelled(labelID: choice.id, labelName: choice.name))
        await onApplied?(message.threadID)
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

    private func record(_ message: MessageSummary, model: String?, _ outcome: ClassificationOutcome) {
        records.append(ClassificationRecord(
            date: now(), threadID: message.threadID, messageID: message.id,
            subject: message.subject, model: model, outcome: outcome
        ))
        if records.count > Self.activityLimit { records.removeFirst(records.count - Self.activityLimit) }
    }
}
