import Foundation
import Synchronization
import Testing

@testable import HeraldKit

// MARK: - Fakes

private actor FakeStore: ClassificationStore {
    var messagesByID: [String: MessageSummary] = [:]
    var labelledThreads: Set<String> = []

    init(_ messages: [MessageSummary], labelled: Set<String> = []) {
        for message in messages { messagesByID[message.id] = message }
        labelledThreads = labelled
    }

    func label(_ threadID: String) { labelledThreads.insert(threadID) }

    func message(id: String, accountID: String) async throws -> MessageSummary? { messagesByID[id] }

    func messages(accountID: String, threadID: String) async throws -> [MessageSummary] {
        messagesByID.values.filter { $0.threadID == threadID }
    }

    func threadHasLabels(threadID: String, accountID: String) async throws -> Bool {
        labelledThreads.contains(threadID)
    }
}

private nonisolated struct FakeBodies: ClassificationBodySource {
    var bodies: [String: String] = [:]
    var fails = false

    func plainText(messageID: String, accountID: String) async throws -> String? {
        if fails { throw MailAPIError.notFound }
        return bodies[messageID]
    }
}

private actor FakeLabeler: ClassificationLabelApplying {
    private(set) var applied: [(label: String, thread: String)] = []
    var fails = false

    func setFails(_ value: Bool) { fails = value }

    func applyLabel(_ labelID: String, toThread threadID: String, accountID: String) async throws {
        if fails { throw MailAPIError.notFound }
        applied.append((labelID, threadID))
    }
}

/// Answers by subject: a candidate name, "none", or an error to throw.
private nonisolated final class FakeClassifier: EmailClassifying, Sendable {
    enum Answer: Sendable { case tag(String), none, error(AIGatewayError) }

    private struct State {
        var inputs: [ClassificationInput] = []
        var inFlight = 0
        var maxInFlight = 0
    }

    private let answers: [String: Answer]
    private let fallback: Answer
    private let state = Mutex(State())
    /// Runs inside `classify`, before it answers — for "something changed while
    /// the model was thinking" races.
    private let during: (@Sendable (ClassificationInput) async -> Void)?

    init(_ answers: [String: Answer] = [:], fallback: Answer = .tag("Support"),
         during: (@Sendable (ClassificationInput) async -> Void)? = nil) {
        self.answers = answers
        self.fallback = fallback
        self.during = during
    }

    var inputs: [ClassificationInput] { state.withLock { $0.inputs } }
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }

    func classify(_ input: ClassificationInput, candidates: [ClassificationCandidate]) async throws -> ClassificationCandidate? {
        state.withLock {
            $0.inputs.append(input)
            $0.inFlight += 1
            $0.maxInFlight = max($0.maxInFlight, $0.inFlight)
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        await Task.yield()
        await during?(input)
        await Task.yield()
        switch answers[input.subject] ?? fallback {
        case .tag(let name): return candidates.first { $0.name == name }
        case .none: return nil
        case .error(let error): throw error
        }
    }
}

private nonisolated final class MemoryAttemptLog: ClassificationAttemptPersisting, Sendable {
    private let storage: Mutex<[String: Date]>
    init(_ initial: [String: Date] = [:]) { storage = Mutex(initial) }
    var saved: [String: Date] { storage.withLock { $0 } }
    func load() -> [String: Date] { storage.withLock { $0 } }
    func save(_ attempts: [String: Date]) { storage.withLock { $0 = attempts } }
}

private nonisolated final class TestClock: Sendable {
    private let current: Mutex<Date>
    init(_ start: Date) { current = Mutex(start) }
    var now: Date { current.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { current.withLock { $0 += seconds } }
}

private nonisolated let enabledAt = Date(timeIntervalSince1970: 10_000)
private nonisolated let support = ClassificationCandidate(id: "l-support", name: "Support", description: "Help requests")
private nonisolated let billing = ClassificationCandidate(id: "l-billing", name: "Billing", description: "Invoices")
private nonisolated let config = AIGatewayConfiguration(accountID: "acct", gatewayID: "gw")

private nonisolated func context(
    mailboxes: [String] = ["mbx"],
    candidates: [ClassificationCandidate] = [support, billing],
    configuration: AIGatewayConfiguration = config
) -> ClassificationContext {
    let rules = ClassificationDomainRules(candidates: candidates, enabledAt: enabledAt)
    return ClassificationContext(
        rulesByMailbox: Dictionary(uniqueKeysWithValues: mailboxes.map { ($0, rules) }),
        configuration: configuration
    )
}

private nonisolated func message(
    _ id: String,
    thread: String? = nil,
    mailbox: String? = "mbx",
    direction: MessageDirection = .inbound,
    folder: MailFolder = .inbox,
    subject: String? = nil,
    received: Date = Date(timeIntervalSince1970: 20_000)
) -> MessageSummary {
    MessageSummary(
        id: id, threadID: thread ?? "t-\(id)", mailboxID: mailbox, direction: direction, folder: folder,
        fromAddress: "Ada <ada@example.net>", to: ["help@example.com"],
        subject: subject ?? "subject \(id)", snippet: "snippet \(id)",
        receivedAt: received, sentAt: nil, readAt: nil, starredAt: nil,
        hasAttachments: false, createdAt: received
    )
}

private nonisolated struct Harness {
    let store: FakeStore
    let labeler = FakeLabeler()
    let classifier: FakeClassifier
    let log: MemoryAttemptLog
    let clock = TestClock(Date(timeIntervalSince1970: 30_000))
    let engine: ClassificationEngine

    init(
        _ messages: [MessageSummary],
        labelled: Set<String> = [],
        classifier: FakeClassifier = FakeClassifier(),
        bodies: FakeBodies = FakeBodies(),
        log: MemoryAttemptLog = MemoryAttemptLog(),
        hourlyLimit: Int = 60
    ) {
        let store = FakeStore(messages, labelled: labelled)
        self.store = store
        self.classifier = classifier
        self.log = log
        let clock = self.clock
        engine = ClassificationEngine(
            store: store, bodies: bodies, labeler: labeler,
            makeClassifier: { _ in classifier },
            attemptLog: log, hourlyLimit: hourlyLimit,
            now: { clock.now }
        )
    }

    func run(_ ids: Set<String>, context: ClassificationContext? = context(), bootstrap: Bool = false) async {
        await engine.handle(ChangeSet(inserted: ids, isBootstrap: bootstrap), accountID: "acc", context: context)
        await engine.waitUntilIdle()
    }

    var appliedThreads: [String] { get async { await labeler.applied.map(\.thread) } }
}

// MARK: - Eligibility (pure)

@Suite("Classification eligibility")
struct ClassificationEligibilityTests {
    private let rules = context().rulesByMailbox

    private func verdict(
        _ message: MessageSummary, rules: [String: ClassificationDomainRules]? = nil,
        attempted: Bool = false, labelled: Bool = false, thread: [MessageSummary]? = nil
    ) -> ClassificationEligibility {
        ClassificationEngine.eligibility(
            of: message, rulesByMailbox: rules ?? self.rules, alreadyAttempted: attempted,
            threadHasLabels: labelled, threadMessages: thread ?? [message]
        )
    }

    @Test func firstInboundUnlabelledInboxMessageIsEligible() {
        guard case .eligible(let found) = verdict(message("m1")) else { Issue.record("not eligible"); return }
        #expect(found.candidates == [support, billing])
    }

    @Test func outboundIsSkipped() {
        #expect(verdict(message("m1", direction: .outbound)) == .skip(.notInbound))
    }

    @Test func nonInboxIsSkipped() {
        #expect(verdict(message("m1", folder: .archived)) == .skip(.notInbox))
    }

    @Test func mailboxOfADomainThatIsOffIsSkipped() {
        #expect(verdict(message("m1", mailbox: "other")) == .skip(.domainOff))
        #expect(verdict(message("m1", mailbox: nil)) == .skip(.domainOff))
    }

    @Test func emptyRulesAreSkipped() {
        #expect(verdict(message("m1"), rules: context(candidates: []).rulesByMailbox) == .skip(.noRules))
    }

    @Test func mailReceivedBeforeEnabledAtIsSkipped() {
        let before = message("m1", received: enabledAt.addingTimeInterval(-1))
        #expect(verdict(before) == .skip(.beforeEnabled))
        // The boundary itself counts as "after".
        guard case .eligible = verdict(message("m1", received: enabledAt)) else { Issue.record("boundary"); return }
    }

    @Test func alreadyAttemptedIsSkipped() {
        #expect(verdict(message("m1"), attempted: true) == .skip(.alreadyAttempted))
    }

    @Test func threadWithAnyLabelIsSkipped() {
        #expect(verdict(message("m1"), labelled: true) == .skip(.threadLabelled))
    }

    @Test func notFirstInboundIsSkipped() {
        let first = message("m1", thread: "t", received: Date(timeIntervalSince1970: 20_000))
        let reply = message("m2", thread: "t", received: Date(timeIntervalSince1970: 21_000))
        #expect(verdict(reply, thread: [first, reply]) == .skip(.notFirstInbound))
        guard case .eligible = verdict(first, thread: [first, reply]) else { Issue.record("first"); return }
    }

    @Test func earlierOutboundDoesNotDisqualify() {
        let mine = message("m0", thread: "t", direction: .outbound, received: Date(timeIntervalSince1970: 15_000))
        let answer = message("m1", thread: "t")
        guard case .eligible = verdict(answer, thread: [mine, answer]) else { Issue.record("outbound first"); return }
    }

    @Test func sameTimestampElectsExactlyOne() {
        let a = message("a", thread: "t")
        let b = message("b", thread: "t")
        #expect(ClassificationEngine.isFirstInbound(a, in: [a, b]))
        #expect(!ClassificationEngine.isFirstInbound(b, in: [a, b]))
    }

    @Test func gatewayLevelErrorsAreTheAccountWideOnes() {
        let pausing: [AIGatewayError] = [.unauthorized, .insufficientCredits, .modelNotAllowed, .blocked, .missingToken, .invalidConfiguration]
        let perMessage: [AIGatewayError] = [.rateLimited, .http(status: 500), .malformedResponse]
        #expect(pausing.allSatisfy(ClassificationEngine.isGatewayLevel))
        #expect(!perMessage.contains(where: ClassificationEngine.isGatewayLevel))
    }
}

// MARK: - Engine

@Suite("Classification engine")
struct ClassificationEngineTests {
    @Test func labelsTheThreadWithTheModelsPick() async {
        let h = Harness([message("m1", subject: "Invoice")], classifier: FakeClassifier(["Invoice": .tag("Billing")]),
                        bodies: FakeBodies(bodies: ["m1": "Please see invoice 42"]))
        await h.run(["m1"])
        #expect(await h.labeler.applied.map(\.label) == ["l-billing"])
        #expect(await h.appliedThreads == ["t-m1"])
        #expect(h.classifier.inputs.map(\.body) == ["Please see invoice 42"])
        let activity = await h.engine.activity
        #expect(activity.map(\.outcome) == [.labelled(labelID: "l-billing", labelName: "Billing")])
        #expect(activity.first?.model == config.model)
        #expect(activity.first?.subject == "Invoice")
    }

    @Test func noneWritesNothing() async {
        let h = Harness([message("m1")], classifier: FakeClassifier(fallback: .none))
        await h.run(["m1"])
        #expect(await h.labeler.applied.isEmpty)
        #expect(await h.engine.activity.map { $0.outcome } == [.none])
    }

    @Test func bodyFallsBackToSnippet() async {
        let h = Harness([message("m1")], bodies: FakeBodies(fails: true))
        await h.run(["m1"])
        #expect(h.classifier.inputs.map(\.body) == ["snippet m1"])
    }

    @Test func noContextMeansNoCalls() async {
        // The app passes nil when the gateway is unconfigured or every domain is off.
        let h = Harness([message("m1")])
        await h.run(["m1"], context: nil)
        #expect(h.classifier.inputs.isEmpty)
    }

    @Test func bootstrapIsNeverClassified() async {
        let h = Harness([message("m1")])
        await h.run(["m1"], bootstrap: true)
        #expect(h.classifier.inputs.isEmpty)
    }

    @Test func ineligibleMessagesNeverReachTheModel() async {
        let first = message("r1", thread: "reply", received: Date(timeIntervalSince1970: 20_000))
        let h = Harness([
            message("out", direction: .outbound),
            message("arch", folder: .archived),
            message("off", mailbox: "other"),
            message("old", received: enabledAt.addingTimeInterval(-60)),
            message("tagged", thread: "tagged-thread"),
            first,
            message("r2", thread: "reply", received: Date(timeIntervalSince1970: 21_000)),
        ], labelled: ["tagged-thread", "reply"])
        await h.run(["out", "arch", "off", "old", "tagged", "r2"])
        #expect(h.classifier.inputs.isEmpty)
        #expect(await h.labeler.applied.isEmpty)
        // Silent reasons stay out of the activity log; meaningful ones are kept.
        let reasons = await h.engine.activity.map { $0.outcome }
        #expect(reasons.contains(.skipped(.beforeEnabled)))
        #expect(reasons.contains(.skipped(.threadLabelled)))
        #expect(!reasons.contains(.skipped(.notInbound)))
    }

    @Test func notFirstInboundOnUnlabelledThreadIsSkipped() async {
        let h = Harness([
            message("a", thread: "t", received: Date(timeIntervalSince1970: 20_000)),
            message("b", thread: "t", received: Date(timeIntervalSince1970: 21_000)),
        ])
        await h.run(["b"])
        #expect(h.classifier.inputs.isEmpty)
        #expect(await h.engine.activity.map { $0.outcome } == [.skipped(.notFirstInbound)])
    }

    @Test func threadLabelledWhileModelAnswersIsLeftAlone() async {
        let storeBox = Mutex<FakeStore?>(nil)
        let classifier = FakeClassifier(during: { _ in
            await storeBox.withLock { $0 }?.label("t-m1")
        })
        let h = Harness([message("m1")], classifier: classifier)
        storeBox.withLock { $0 = h.store }
        await h.run(["m1"])
        #expect(classifier.inputs.count == 1)
        #expect(await h.labeler.applied.isEmpty)
        #expect(await h.engine.activity.map { $0.outcome } == [.skipped(.labelledMeanwhile)])
    }

    @Test func memoPreventsARepeat() async {
        let h = Harness([message("m1")], classifier: FakeClassifier(fallback: .none))
        await h.run(["m1"])
        await h.run(["m1"])
        #expect(h.classifier.inputs.count == 1)
    }

    @Test func persistedAttemptSurvivesARelaunch() async {
        let log = MemoryAttemptLog()
        let first = Harness([message("m1")], classifier: FakeClassifier(fallback: .none), log: log)
        await first.run(["m1"])
        #expect(log.saved.keys.sorted() == ["t-m1"])

        let relaunched = Harness([message("m1")], log: log)
        await relaunched.run(["m1"])
        #expect(relaunched.classifier.inputs.isEmpty)
    }

    @Test func hourlyCapSkipsTheExcessAndRecoversAfterAnHour() async {
        let h = Harness([message("a"), message("b"), message("c")], hourlyLimit: 2)
        await h.run(["a", "b", "c"])
        #expect(h.classifier.inputs.map(\.subject) == ["subject a", "subject b"])
        #expect(await h.engine.activity.last?.outcome == .skipped(.hourlyCap))

        h.clock.advance(3_600)
        await h.store.insert(message("d"))
        await h.run(["d"])
        #expect(h.classifier.inputs.map(\.subject).last == "subject d")
    }

    @Test func processesOneAtATimeInIDOrder() async {
        let h = Harness([message("c"), message("a"), message("b")])
        await h.run(["c", "a", "b"])
        #expect(h.classifier.inputs.map(\.subject) == ["subject a", "subject b", "subject c"])
        #expect(h.classifier.maxInFlight == 1)
    }

    @Test func overlappingPassesStillRunSerially() async {
        let h = Harness([message("a"), message("b")])
        async let one: Void = h.engine.handle(ChangeSet(inserted: ["a"]), accountID: "acc", context: context())
        async let two: Void = h.engine.handle(ChangeSet(inserted: ["b", "a"]), accountID: "acc", context: context())
        _ = await (one, two)
        await h.engine.waitUntilIdle()
        #expect(h.classifier.inputs.count == 2)
        #expect(h.classifier.maxInFlight == 1)
    }

    @Test func gatewayErrorPausesAndSurfacesOnce() async {
        let classifier = FakeClassifier(fallback: .error(.unauthorized))
        let h = Harness([message("a"), message("b"), message("c")], classifier: classifier)
        let surfaced = Mutex<[AIGatewayError?]>([])
        await h.engine.setObservers(onApplied: nil, onPauseChanged: { reason in surfaced.withLock { $0.append(reason) } })
        await h.run(["a", "b"])
        await h.run(["c"])
        #expect(classifier.inputs.count == 1)
        #expect(surfaced.withLock { $0 } == [.unauthorized])
        #expect(await h.engine.pauseReason == .unauthorized)
        #expect(await h.engine.activity.map { $0.outcome } == [.failed(reason: "unauthorized"), .skipped(.paused)])
    }

    @Test func changedConfigurationResumes() async {
        let h = Harness([message("a"), message("b")], classifier: FakeClassifier(["subject a": .error(.modelNotAllowed)]))
        let surfaced = Mutex<[AIGatewayError?]>([])
        await h.engine.setObservers(onApplied: nil, onPauseChanged: { reason in surfaced.withLock { $0.append(reason) } })
        await h.run(["a"])
        #expect(await h.engine.pauseReason == .modelNotAllowed)
        await h.run(["b"], context: context(configuration: AIGatewayConfiguration(accountID: "acct", gatewayID: "gw", model: "workers-ai/other")))
        #expect(await h.engine.pauseReason == nil)
        #expect(await h.appliedThreads == ["t-b"])
        #expect(surfaced.withLock { $0 } == [.modelNotAllowed, nil])
    }

    @Test func pauseBeforeObserversIsReplayed() async {
        let h = Harness([message("a")], classifier: FakeClassifier(fallback: .error(.insufficientCredits)))
        await h.run(["a"])
        let surfaced = Mutex<[AIGatewayError?]>([])
        await h.engine.setObservers(onApplied: nil, onPauseChanged: { reason in surfaced.withLock { $0.append(reason) } })
        #expect(surfaced.withLock { $0 } == [.insufficientCredits])
    }

    @Test func perMessageErrorContinuesWithTheNext() async {
        let classifier = FakeClassifier(["subject a": .error(.rateLimited), "subject b": .error(.malformedResponse)])
        let h = Harness([message("a"), message("b"), message("c")], classifier: classifier)
        await h.run(["a", "b", "c"])
        #expect(await h.engine.pauseReason == nil)
        #expect(await h.appliedThreads == ["t-c"])
    }

    @Test func labelWriteFailureIsRecordedAndTheQueueContinues() async {
        let h = Harness([message("a"), message("b")])
        await h.labeler.setFails(true)
        await h.run(["a", "b"])
        #expect(await h.engine.activity.map { $0.outcome } == [.failed(reason: "labelWrite"), .failed(reason: "labelWrite")])
    }

    @Test func activityRingIsBounded() async {
        let messages = (0..<(ClassificationEngine.activityLimit + 20)).map { message(String(format: "m%03d", $0)) }
        let h = Harness(messages, classifier: FakeClassifier(fallback: .none), hourlyLimit: 10_000)
        for chunk in stride(from: 0, to: messages.count, by: 100) {
            await h.run(Set(messages[chunk..<min(chunk + 100, messages.count)].map(\.id)))
        }
        #expect(await h.engine.activity.count == ClassificationEngine.activityLimit)
    }

    @Test func stopMidRequestWritesNothingAndDropsTheQueue() async {
        let engineBox = Mutex<ClassificationEngine?>(nil)
        let stopping = Mutex<Task<Void, Never>?>(nil)
        let classifier = FakeClassifier(during: { _ in
            guard let engine = engineBox.withLock({ $0 }) else { return }
            let task = Task { await engine.stop() }
            stopping.withLock { $0 = task }
            // Let stop() cancel the drain before the model "answers".
            try? await Task.sleep(for: .milliseconds(50))
        })
        let h = Harness([message("a"), message("b")], classifier: classifier)
        engineBox.withLock { $0 = h.engine }
        await h.run(["a", "b"])
        await stopping.withLock { $0 }?.value
        #expect(classifier.inputs.count == 1)
        #expect(await h.labeler.applied.isEmpty)
    }

    @Test func failureCodesCarryNoPayload() {
        #expect(ClassificationEngine.code(for: .http(status: 503)) == "http503")
        #expect(ClassificationEngine.code(for: .unauthorized) == "unauthorized")
    }

    @Test func appliedObserverGetsTheThread() async {
        let h = Harness([message("a")])
        let applied = Mutex<[String]>([])
        await h.engine.setObservers(onApplied: { thread in applied.withLock { $0.append(thread) } }, onPauseChanged: nil)
        await h.run(["a"])
        #expect(applied.withLock { $0 } == ["t-a"])
    }
}

private extension FakeStore {
    func insert(_ message: MessageSummary) { messagesByID[message.id] = message }
}

// MARK: - MailStore

@Suite("MailStore thread label check")
struct MailStoreThreadLabelTests {
    @Test func reportsAnyLabelOnAnyMessageOfTheThread() async throws {
        let store = try MailStore.inMemory()
        _ = try await store.upsertMessages([message("m1", thread: "t"), message("m2", thread: "t"), message("x", thread: "u")], accountID: "acc")
        #expect(try await !store.threadHasLabels(threadID: "t", accountID: "acc"))
        _ = try await store.applyLocalLabel("l-support", threadID: "t", accountID: "acc", assigned: true)
        #expect(try await store.threadHasLabels(threadID: "t", accountID: "acc"))
        #expect(try await !store.threadHasLabels(threadID: "u", accountID: "acc"))
        #expect(try await !store.threadHasLabels(threadID: "t", accountID: "other"))
    }
}
