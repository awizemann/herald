import Foundation

/// Which account-tint token an account is drawn in — the redesign's replacement
/// for the per-mailbox colour palette (`MailboxColorAssignment`, still in place
/// until R3b removes it).
///
/// Deliberately independent of `MailTheme`: the tint *colours* for these eight
/// names are defined by the parallel R1 (tokens) phase, not here. This type only
/// resolves which NAME an account gets; the view layer (R4+) looks that name up
/// in `MailTheme` once R1 has landed. Reuses `MailboxColorAssignment.stableHash`
/// — the same FNV-1a hash, not a second implementation of it — keyed on the
/// account id instead of a mailbox address.
nonisolated enum AccountTintAssignment {
    /// Fixed contract with R1's `MailTheme` account-tint colours: this exact
    /// order. Appending a new name is safe (existing hashes are unaffected
    /// only if it goes at the end); reordering or removing one is not — it
    /// would reassign every account's default tint and break the persistence
    /// contract on `override` values already written to disk.
    static let tokenNames = ["clay", "ochre", "moss", "sage", "slate", "dusk", "plum", "rose"]

    /// The tint an account gets when nobody has overridden it. Stable forever
    /// for a given account id, the same reasoning as
    /// `MailboxColorAssignment.defaultToken(forAddress:)`: `Hasher` is
    /// per-process-seeded and unusable here.
    ///
    /// Unlike the mailbox hash, the account id is NOT lowercased first: an
    /// `accountID` is `Account.normalize(origin).absoluteString` (see "Herald
    /// Architecture"), already a single canonical casing, not a user-typed
    /// email address that could vary.
    static func defaultToken(forAccountID accountID: String) -> String {
        let index = Int(MailboxColorAssignment.stableHash(accountID) % UInt64(tokenNames.count))
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
    static func storageKey(accountID: String) -> String {
        "account.\(accountID).tint"
    }
}
