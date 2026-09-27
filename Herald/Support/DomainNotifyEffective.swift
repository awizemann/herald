import Foundation

/// What a domain's "Notify me about new mail" toggle shows and does, on top of
/// ``DomainPreferences``' tri-state `notify` (`nil` = follow the global switch).
///
/// The write side lives entirely in ``DomainPreferences/setNotify(_:accountID:domainID:in:)``
/// and ``NewMailNotifier/isSilenced(_:silencedMailboxIDs:)`` — this is only the
/// READ half the Settings › Domain › Overview toggle needs, kept pure and
/// `nonisolated` so the rule (global OFF always wins) is assertable without a
/// view or `UserDefaults` in play.
nonisolated enum DomainNotifyEffective {
    /// The state the switch draws: `nil` follows the global setting, so the
    /// effective value is whatever it is; an explicit `true`/`false` shows as
    /// itself — UNLESS the global switch is off, which always wins (the same
    /// rule ``MailViewModel/notificationSilencedMailboxIDs()`` enforces for
    /// actual banners: a domain's explicit `true` cannot override a global OFF).
    static func effective(explicit: Bool?, globalEnabled: Bool) -> Bool {
        guard globalEnabled else { return false }
        return explicit ?? true
    }
}
