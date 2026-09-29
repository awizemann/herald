import Foundation
import HeraldKit
import Synchronization
import Testing

@testable import Herald

private nonisolated final class ContextSecrets: SecretStore, Sendable {
    private let storage = Mutex<[String: Data]>([:])
    func data(for key: String) throws -> Data? { storage.withLock { $0[key] } }
    func set(_ data: Data, for key: String) throws { storage.withLock { $0[key] = data } }
    func removeValue(for key: String) throws { storage.withLock { $0[key] = nil } }
}

/// WF4's app half: which mailboxes a pass may classify, resolved from
/// Workflows + AI Gateway preferences.
@Suite("Classification context", .scratchDefaults)
struct ClassificationContextTests {
    private let account = "https://mail.example"
    private let support = MailLabel(id: "l-support", name: "Support", color: .blue)
    private let acme = MailDomain(id: "d-acme", name: "acme.com", mailboxIDs: ["mb-1", "mb-2"])
    private let other = MailDomain(id: "d-other", name: "other.com", mailboxIDs: ["mb-3"])

    private func configuredGateway(_ defaults: UserDefaults) throws -> ContextSecrets {
        AIGatewaySettings.setAccountID("acct", in: defaults)
        AIGatewaySettings.setGatewayID("gw", in: defaults)
        let secrets = ContextSecrets()
        try AIGatewaySettings.saveToken("token", in: secrets)
        return secrets
    }

    private func enable(_ domain: MailDomain, describe: Bool = true, _ defaults: UserDefaults) {
        WorkflowPreferences.setEnabled(true, accountID: account, domainID: domain.id, in: defaults, now: Date(timeIntervalSince1970: 5))
        WorkflowPreferences.setLabelRule(
            WorkflowLabelRule(included: true, description: describe ? "Help requests" : " "),
            labelID: support.id, accountID: account, domainID: domain.id, in: defaults
        )
    }

    private func build(_ defaults: UserDefaults, _ secrets: any SecretStore) -> ClassificationContext? {
        ClassificationContextBuilder.context(
            accountID: account, domains: [acme, other], labels: [support], defaults: defaults, secrets: secrets
        )
    }

    @Test func enabledDomainMapsEveryMailboxAndOnlyThose() throws {
        let defaults = ScratchDefaults.make()
        let secrets = try configuredGateway(defaults)
        enable(acme, defaults)
        let context = try #require(build(defaults, secrets))
        #expect(Set(context.rulesByMailbox.keys) == ["mb-1", "mb-2"])
        #expect(context.rulesByMailbox["mb-1"]?.candidates.map(\.id) == [support.id])
        #expect(context.rulesByMailbox["mb-1"]?.enabledAt == Date(timeIntervalSince1970: 5))
        #expect(context.configuration.model.hasPrefix(AIGatewaySettings.providerPrefix))
    }

    @Test func domainOffGivesNoContext() throws {
        let defaults = ScratchDefaults.make()
        #expect(build(defaults, try configuredGateway(defaults)) == nil)
    }

    @Test func rulesEmptyGivesNoContext() throws {
        let defaults = ScratchDefaults.make()
        let secrets = try configuredGateway(defaults)
        enable(acme, describe: false, defaults)
        #expect(build(defaults, secrets) == nil)
    }

    @Test func unconfiguredGatewayGivesNoContext() throws {
        let defaults = ScratchDefaults.make()
        enable(acme, defaults)
        // IDs saved but no token.
        AIGatewaySettings.setAccountID("acct", in: defaults)
        AIGatewaySettings.setGatewayID("gw", in: defaults)
        #expect(build(defaults, ContextSecrets()) == nil)
    }

    @Test func attemptLogRoundTripsAndIsPurgedOnSignOut() {
        let defaults = ScratchDefaults.make()
        let log = WorkflowAttemptLog(accountID: account, defaults: defaults)
        let when = Date(timeIntervalSince1970: 99)
        log.save(["t1": when])
        #expect(log.load() == ["t1": when])
        WorkflowPreferences.purgeAll(accountID: account, from: defaults)
        #expect(log.load().isEmpty)
    }

    @Test func pauseTextNamesTheCause() {
        let text = DomainWorkflowsSettingsPage.pauseText(.unauthorized)
        #expect(text.contains(AIGatewaySettings.message(for: .unauthorized)))
        #expect(text.hasPrefix("Classification is paused"))
    }
}

// MARK: - Activity log (WF5)

private actor ActivitySync: MailSyncing {
    func refreshNow() {}
    func refreshDraftsNow() {}
    func refreshLabelsNow() {}
    func setCadence(_ cadence: SyncCadence) {}
    func setLabelSurfaceVisible(_ visible: Bool) {}
}

@Suite("Workflows activity log")
struct WorkflowActivityTests {
    private func record(_ id: String, mailbox: String?, at seconds: TimeInterval,
                        _ outcome: ClassificationOutcome = .none) -> ClassificationRecord {
        ClassificationRecord(
            date: Date(timeIntervalSince1970: seconds), threadID: "t-\(id)", messageID: id,
            mailboxID: mailbox, subject: id, model: "workers-ai/@cf/meta/llama-3.1-8b-instruct-fp8", outcome: outcome
        )
    }

    /// Fails if another domain's (or a mailbox-less) record leaks in, if the
    /// order is not newest first, or if the cap keeps the OLDEST entries.
    @Test func filtersToTheDomainNewestFirstAndCaps() {
        var records = (0..<25).map { record("m\($0)", mailbox: "mbA", at: TimeInterval($0)) }
        records.append(record("other", mailbox: "mbZ", at: 100))
        records.append(record("orphan", mailbox: nil, at: 101))
        let shown = DomainWorkflowsSettingsPage.recentActivity(records, mailboxIDs: ["mbA", "mbB"])
        #expect(shown.count == DomainWorkflowsSettingsPage.activityLimit)
        #expect(shown.first?.messageID == "m24")
        #expect(shown.last?.messageID == "m5")
        #expect(!shown.contains { $0.messageID == "other" || $0.messageID == "orphan" })
    }

    @Test func outcomesReadAsPlainEnglish() {
        #expect(DomainWorkflowsSettingsPage.outcomeText(.none) == "No tag")
        #expect(DomainWorkflowsSettingsPage.outcomeText(.labelled(labelID: "l", labelName: "Billing")) == "Tagged Billing")
        #expect(DomainWorkflowsSettingsPage.outcomeText(.skipped(.threadLabelled)).contains("already has a tag"))
        #expect(DomainWorkflowsSettingsPage.outcomeText(.failed(reason: "http503")) == "Failed — the gateway answered 503")
        #expect(DomainWorkflowsSettingsPage.outcomeText(.failed(reason: "threadCheck")).contains("server"))
        #expect(DomainWorkflowsSettingsPage.outcomeText(.failed(reason: "zzz")) == "Failed — an unexpected error")
        // No camelCase code leaks through as-is (a one-word code like `paused`
        // is also ordinary English).
        for reason in ClassificationSkipReason.allCases where reason.rawValue != reason.rawValue.lowercased() {
            #expect(!DomainWorkflowsSettingsPage.outcomeText(.skipped(reason)).contains(reason.rawValue))
        }
        #expect(DomainWorkflowsSettingsPage.modelName("workers-ai/@cf/meta/llama-3.1-8b-instruct-fp8") == "llama-3.1-8b-instruct-fp8")
    }

    /// Fails if a snapshot that lost the race to the main actor overwrites a newer one.
    @Test @MainActor func staleSnapshotIsIgnored() throws {
        let store = try MailStore.inMemory()
        let api = FakeMailAPIClient()
        let (stream, _) = AsyncStream<SyncEvent>.makeStream()
        let model = MailViewModel(
            accountID: "acct", accountLabel: "Test", api: api, store: store,
            actions: MailActionService(api: api, store: store), sync: ActivitySync(), events: stream
        )
        let newer = [record("a", mailbox: "mbA", at: 1), record("b", mailbox: "mbA", at: 2)]
        model.classificationActivityChanged(ClassificationActivitySnapshot(version: 2, records: newer))
        model.classificationActivityChanged(ClassificationActivitySnapshot(version: 1, records: [newer[0]]))
        #expect(model.classificationActivity.map(\.messageID) == ["a", "b"])
    }
}
