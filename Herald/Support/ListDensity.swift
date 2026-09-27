import Foundation

/// Settings › General's row-density choice. Applies to every account (it is not
/// scoped per account, unlike ``DomainPreferences``), stored at `list.density`.
nonisolated enum ListDensity: String, Sendable, CaseIterable {
    case comfortable
    case compact

    static let storageKey = "list.density"

    /// Comfortable is the default (design spec §1) — an absent or unrecognised
    /// stored value (a future case this build doesn't know, or manual defaults
    /// tampering) falls back to it rather than to whatever `Compact` happens to
    /// mean today.
    static func current(in defaults: UserDefaults) -> ListDensity {
        guard let raw = defaults.string(forKey: storageKey), let value = ListDensity(rawValue: raw) else {
            return .comfortable
        }
        return value
    }

    static func set(_ value: ListDensity, in defaults: UserDefaults) {
        defaults.set(value.rawValue, forKey: storageKey)
    }
}
