import Foundation

/// Which palette token a mailbox is drawn in.
///
/// Pure and `nonisolated` on purpose: the assignment has to be identical on every
/// launch and every machine, and that is only assertable off-screen. Swift's
/// `Hashable` is NOT usable here — `Hasher` is seeded per process, so the same
/// address would land on a different colour after a relaunch. FNV-1a over the
/// lowercased UTF-8 is stable forever.
nonisolated enum MailboxColorAssignment {
    /// The token names, in palette order.
    static var tokenNames: [String] { MailTheme.mailboxPalette.map(\.name) }

    /// The colour a mailbox gets when nobody has chosen one, derived from its
    /// address so the same mailbox is the same colour everywhere.
    static func defaultToken(forAddress address: String) -> String {
        let palette = MailTheme.mailboxPalette
        guard palette.isEmpty == false else { return "" }
        let index = Int(stableHash(address.lowercased()) % UInt64(palette.count))
        return palette[index].name
    }

    /// Override wins; an override naming a token this build no longer has falls
    /// back to the default rather than drawing nothing.
    static func token(forAddress address: String, override: String?) -> String {
        if let override, MailTheme.mailboxTint(named: override) != nil { return override }
        return defaultToken(forAddress: address)
    }

    /// The UserDefaults key one mailbox's override is stored under. Scoped by
    /// account: two accounts can hold the same mailbox id.
    static func storageKey(accountID: String, mailboxID: String) -> String {
        "mailboxColor.\(accountID).\(mailboxID)"
    }

    /// FNV-1a, 64-bit.
    private static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return hash
    }
}
