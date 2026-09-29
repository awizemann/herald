import Foundation
import HeraldKit

/// Builds each pass's ``ClassificationContext`` from Herald-only preferences.
/// Pure over its inputs so every "off" path is testable without an engine.
nonisolated enum ClassificationContextBuilder {
    /// `nil` when nothing may be classified this pass: the gateway is not
    /// configured (the toggle can outlive a removed gateway), or no domain has
    /// classification on with at least one usable label.
    static func context(
        accountID: String,
        domains: [MailDomain],
        labels: [MailLabel],
        defaults: UserDefaults,
        secrets: any SecretStore
    ) -> ClassificationContext? {
        var rulesByMailbox: [String: ClassificationDomainRules] = [:]
        for domain in domains {
            guard let candidates = WorkflowPreferences.classificationRules(
                accountID: accountID, domainID: domain.id, labels: labels, in: defaults
            ), !candidates.isEmpty,
                let enabledAt = WorkflowPreferences.enabledAt(accountID: accountID, domainID: domain.id, in: defaults)
            else { continue }
            let rules = ClassificationDomainRules(candidates: candidates, enabledAt: enabledAt)
            for mailboxID in domain.mailboxIDs { rulesByMailbox[mailboxID] = rules }
        }
        // Checked last: the Keychain read is the expensive part, and most
        // passes end above with no domain switched on.
        guard !rulesByMailbox.isEmpty,
              AIGatewaySettings.isConfigured(in: defaults, secrets: secrets),
              let configuration = AIGatewaySettings.configuration(in: defaults)
        else { return nil }
        return ClassificationContext(rulesByMailbox: rulesByMailbox, configuration: configuration)
    }
}

/// Threads already sent to the model, kept for a week under
/// `workflow.<accountID>.attempts` so a relaunch never re-classifies a thread
/// that got "none". Three key components, so it cannot collide with a
/// per-domain `workflow.<acct>.<domain>.<field>` key, and sign-out's
/// ``WorkflowPreferences/purgeAll(accountID:from:)`` removes it.
///
/// `@unchecked Sendable`: its only state is `UserDefaults`, which is documented
/// thread-safe but not annotated `Sendable`.
nonisolated struct WorkflowAttemptLog: ClassificationAttemptPersisting, @unchecked Sendable {
    let accountID: String
    let defaults: UserDefaults

    static func key(accountID: String) -> String {
        "\(WorkflowPreferences.prefix)\(DomainPreferences.escapeKeyComponent(accountID)).attempts"
    }

    func load() -> [String: Date] {
        (defaults.dictionary(forKey: Self.key(accountID: accountID)) as? [String: Date]) ?? [:]
    }

    func save(_ attempts: [String: Date]) {
        defaults.set(attempts, forKey: Self.key(accountID: accountID))
    }
}
