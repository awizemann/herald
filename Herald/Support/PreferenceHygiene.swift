import Foundation

/// Removes Herald-only preferences nothing will read again. Two jobs, both
/// over an injected `UserDefaults` like ``DomainPreferences``:
///
/// - ``purgeAccount(_:from:)`` — sign-out: everything keyed by ONE account id.
/// - ``purgeLegacyMailboxColorsOnce(in:)`` — the per-mailbox colour overrides
///   the redesign retired, removed once per install.
nonisolated enum PreferenceHygiene {
    /// Everything this Mac stored for one account that is not the Keychain's or
    /// the cache's to clean up: its domain preferences, its saved navigation
    /// (including the pre-redesign key, should it never have been migrated) and
    /// its tint override. A later sign-in to the same origin then starts clean,
    /// exactly like a first sign-in.
    ///
    /// Every key but the domain preferences is removed by its EXACT name, so an
    /// account id that is a prefix of another's (`https://mail.x` vs
    /// `https://mail.x.y`) cannot reach the other account's keys; the domain
    /// preferences are prefix-scanned, and ``DomainPreferences`` escapes the id
    /// for exactly that reason.
    static func purgeAccount(_ accountID: String, from defaults: UserDefaults) {
        DomainPreferences.purgeAll(accountID: accountID, from: defaults)
        WorkflowPreferences.purgeAll(accountID: accountID, from: defaults)
        for key in [
            NavigationPersistence.scopeKey(accountID: accountID),
            NavigationPersistence.folderKey(accountID: accountID),
            NavigationPersistence.labelKey(accountID: accountID),
            NavigationPersistence.legacyMailboxKey(accountID: accountID),
            AccountTintAssignment.storageKey(accountID: accountID),
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Records that the legacy purge ran. Its own key rather than "no
    /// `mailboxColor.*` key exists": the scan walks the whole defaults domain,
    /// and it only needs to do that once.
    static let legacyMailboxColorPurgeKey = "migration.mailboxColorPurged"

    /// The retired per-mailbox colour overrides lived at
    /// `mailboxColor.<accountID>.<mailboxID>`.
    static let legacyMailboxColorPrefix = "mailboxColor."

    /// Removes every stored per-mailbox colour override, once. Returns whether
    /// this call did the purge (`false` on every call after the first).
    @discardableResult
    static func purgeLegacyMailboxColorsOnce(in defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: legacyMailboxColorPurgeKey) else { return false }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(legacyMailboxColorPrefix) {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: legacyMailboxColorPurgeKey)
        return true
    }
}
