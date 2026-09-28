import Foundation

/// Which account-tint token an account is drawn in — the redesign's replacement
/// for the per-mailbox colour palette (removed in R3b: an account is the only
/// thing that gets its own hue).
///
/// Deliberately independent of `MailTheme`: this type only resolves which NAME
/// an account gets; the view layer looks that name up with
/// `MailTheme.accountTint(named:)`. Pure and `nonisolated` so the assignment is
/// assertable off-screen — it has to be identical on every launch and machine.
nonisolated enum AccountTintAssignment {
    /// Fixed contract with R1's `MailTheme` account-tint colours: this exact
    /// order, and this exact COUNT. The default is `stableHash % count`, so
    /// changing the list in ANY way — appending included — repaints most
    /// accounts' defaults (only an override survives). Removing or renaming a
    /// token additionally strands `override` values already written to disk
    /// (they fall back to the default). Treat a change here as a visible
    /// migration, not a free addition.
    static let tokenNames = ["clay", "ochre", "moss", "sage", "slate", "dusk", "plum", "rose"]

    /// The tint an account gets when nobody has overridden it. Stable forever
    /// for a given account id: Swift's `Hasher` is seeded per process, so it
    /// would repaint every account on relaunch — ``stableHash(_:)`` is not.
    ///
    /// The account id is NOT lowercased first: an
    /// `accountID` is `Account.normalize(origin).absoluteString` (see "Herald
    /// Architecture"), already a single canonical casing, not a user-typed
    /// email address that could vary.
    static func defaultToken(forAccountID accountID: String) -> String {
        let index = Int(stableHash(accountID) % UInt64(tokenNames.count))
        return tokenNames[index]
    }

    /// Override wins; an override naming a token this build no longer has (a
    /// stale value from a build with a different `tokenNames`, or a corrupted
    /// default) falls back to the hash default rather than drawing nothing.
    static func token(forAccountID accountID: String, override: String?) -> String {
        if let override, tokenNames.contains(override) { return override }
        return defaultToken(forAccountID: accountID)
    }

    /// The UserDefaults key one account's tint override is stored under.
    ///
    /// Read and written only by exact key (never scanned or prefix-matched
    /// across accounts, unlike `DomainPreferences`), so an `accountID`
    /// containing `.` cannot cause the same one-account's-keys-look-like-
    /// another's collision `DomainPreferences` had to escape against.
    static func storageKey(accountID: String) -> String {
        "account.\(accountID).tint"
    }

    /// FNV-1a-shaped, 64-bit, over the UTF-8 bytes. Stable forever — the reason
    /// it exists instead of `hashValue`. Moved here from the removed
    /// per-mailbox `MailboxColorAssignment` unchanged, so every account keeps
    /// the default tint it had.
    ///
    /// NOTE the multiplier is `0x1000_0000_01b3` (= 0x1000000001b3), not the
    /// FNV prime 0x100000001b3 — a digit-grouping slip from the start. It still
    /// spreads well (the tests check it) and it is what every stored default
    /// was derived under, so it is kept; "fixing" it would repaint every
    /// account that has no override.
    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return hash
    }
}
