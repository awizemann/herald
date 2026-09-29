import Foundation
import HeraldKit

/// One workspace label's classification rule for one domain: whether the
/// classifier may pick it, and the one-line description the model sees.
nonisolated struct WorkflowLabelRule: Sendable, Hashable {
    var included: Bool
    var description: String

    static let empty = WorkflowLabelRule(included: false, description: "")
}

/// Why a turned-on classification setup may not do what the user expects —
/// the Workflows page's warning.
nonisolated enum WorkflowSetupWarning: Sendable, Hashable {
    /// On, but no existing label is included.
    case noLabelsIncluded
    /// These included labels (names) have no description, so they are
    /// left out of classification until they get one.
    case missingDescriptions([String])
}

/// Herald-only, per-(account, domain) email-classification settings
/// (Settings › {domain} › Workflows). Same injected-`defaults`, static-func
/// shape as ``DomainPreferences`` and the same escaped key components
/// (``DomainPreferences/escapeKeyComponent(_:)``), under its own prefix:
///
/// - `workflow.<accountID>.<domainID>.classify` — Bool, default off.
/// - `workflow.<accountID>.<domainID>.enabledAt` — Date, stamped every time
///   classification is turned ON; only mail received after it is classified.
/// - `workflow.<accountID>.<domainID>.labels` — `[labelID: [included, description]]`.
///   Label ids live inside the dictionary, not the key, so they need no escaping.
nonisolated enum WorkflowPreferences {
    static let prefix = "workflow."

    private static func key(_ field: String, accountID: String, domainID: String) -> String {
        "\(prefix)\(DomainPreferences.escapeKeyComponent(accountID)).\(DomainPreferences.escapeKeyComponent(domainID)).\(field)"
    }

    static func enabledKey(accountID: String, domainID: String) -> String {
        key("classify", accountID: accountID, domainID: domainID)
    }

    static func enabledAtKey(accountID: String, domainID: String) -> String {
        key("enabledAt", accountID: accountID, domainID: domainID)
    }

    static func labelsKey(accountID: String, domainID: String) -> String {
        key("labels", accountID: accountID, domainID: domainID)
    }

    private static let includedField = "included"
    private static let descriptionField = "description"

    // MARK: - Enabled

    static func isEnabled(accountID: String, domainID: String, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey(accountID: accountID, domainID: domainID)) as? Bool ?? false
    }

    /// When classification was last turned on; `nil` while off.
    static func enabledAt(accountID: String, domainID: String, in defaults: UserDefaults) -> Date? {
        defaults.object(forKey: enabledAtKey(accountID: accountID, domainID: domainID)) as? Date
    }

    /// Turning on stamps `enabledAt = now` — every time, so off-then-on moves
    /// the cutoff forward and mail that arrived while it was off is never
    /// classified retroactively. Turning off clears both keys. Setting the
    /// value it already has is a no-op (a repeated `true` must not move the
    /// cutoff).
    static func setEnabled(_ enabled: Bool, accountID: String, domainID: String, in defaults: UserDefaults, now: Date = Date()) {
        guard enabled != isEnabled(accountID: accountID, domainID: domainID, in: defaults) else { return }
        let enabledKey = enabledKey(accountID: accountID, domainID: domainID)
        let enabledAtKey = enabledAtKey(accountID: accountID, domainID: domainID)
        if enabled {
            defaults.set(true, forKey: enabledKey)
            defaults.set(now, forKey: enabledAtKey)
        } else {
            defaults.removeObject(forKey: enabledKey)
            defaults.removeObject(forKey: enabledAtKey)
        }
    }

    // MARK: - Label rules

    /// Every stored rule, keyed by label id — including rules for labels that
    /// have since been deleted server-side (readers filter by the live list).
    static func labelRules(accountID: String, domainID: String, in defaults: UserDefaults) -> [String: WorkflowLabelRule] {
        guard let raw = defaults.dictionary(forKey: labelsKey(accountID: accountID, domainID: domainID)) else { return [:] }
        var rules: [String: WorkflowLabelRule] = [:]
        for (labelID, value) in raw {
            guard let fields = value as? [String: Any] else { continue }
            rules[labelID] = WorkflowLabelRule(
                included: fields[includedField] as? Bool ?? false,
                description: fields[descriptionField] as? String ?? ""
            )
        }
        return rules
    }

    static func labelRule(labelID: String, accountID: String, domainID: String, in defaults: UserDefaults) -> WorkflowLabelRule {
        labelRules(accountID: accountID, domainID: domainID, in: defaults)[labelID] ?? .empty
    }

    /// Writes one label's rule; an empty rule (excluded, no description) is
    /// removed rather than stored.
    static func setLabelRule(_ rule: WorkflowLabelRule, labelID: String, accountID: String, domainID: String, in defaults: UserDefaults) {
        let key = labelsKey(accountID: accountID, domainID: domainID)
        var raw = defaults.dictionary(forKey: key) ?? [:]
        if rule.included || !rule.description.isEmpty {
            raw[labelID] = [includedField: rule.included, descriptionField: rule.description]
        } else {
            raw.removeValue(forKey: labelID)
        }
        if raw.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(raw, forKey: key)
        }
    }

    // MARK: - For the classifier (WF4)

    /// The candidates the classifier may choose from for mail in this domain,
    /// or `nil` when classification is off. Only labels in `labels` (the live
    /// workspace list — a stored rule for a deleted label is ignored) that are
    /// included AND have a non-blank description are returned, in `labels`'
    /// order. On but nothing usable returns `[]` — the caller should then skip
    /// classification, same as `nil`.
    static func classificationRules(
        accountID: String,
        domainID: String,
        labels: [MailLabel],
        in defaults: UserDefaults
    ) -> [ClassificationCandidate]? {
        guard isEnabled(accountID: accountID, domainID: domainID, in: defaults) else { return nil }
        let rules = labelRules(accountID: accountID, domainID: domainID, in: defaults)
        return labels.compactMap { label in
            guard let rule = rules[label.id], rule.included else { return nil }
            let description = rule.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty else { return nil }
            return ClassificationCandidate(id: label.id, name: label.name, description: description)
        }
    }

    /// The page's warning, or `nil` when off or set up completely.
    static func setupWarning(
        accountID: String,
        domainID: String,
        labels: [MailLabel],
        in defaults: UserDefaults
    ) -> WorkflowSetupWarning? {
        guard isEnabled(accountID: accountID, domainID: domainID, in: defaults) else { return nil }
        let rules = labelRules(accountID: accountID, domainID: domainID, in: defaults)
        let included = labels.filter { rules[$0.id]?.included == true }
        guard !included.isEmpty else { return .noLabelsIncluded }
        let undescribed = included
            .filter { rules[$0.id]?.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true }
            .map(\.name)
        return undescribed.isEmpty ? nil : .missingDescriptions(undescribed)
    }

    // MARK: - Purge

    /// Removes every `workflow.<accountID>.*` key — sign-out, via
    /// ``PreferenceHygiene/purgeAccount(_:from:)``. The escaped id makes the
    /// prefix exact (see ``DomainPreferences/escapeKeyComponent(_:)``).
    static func purgeAll(accountID: String, from defaults: UserDefaults) {
        let accountPrefix = "\(prefix)\(DomainPreferences.escapeKeyComponent(accountID))."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(accountPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
