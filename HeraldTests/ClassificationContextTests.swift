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
