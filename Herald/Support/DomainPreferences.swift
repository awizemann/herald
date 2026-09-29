import Foundation

/// Herald-only, per-(account, domain) preferences — nothing here is server
/// state, so it lives entirely in `UserDefaults`, following the same injected-
/// `defaults` pattern as ``NotificationSettings``/``AccountTintAssignment``
/// rather than reaching for `.standard` directly (tests use `ScratchDefaults`).
///
/// A value-type API (read/write pairs of `static func`s, not a stored object)
/// so a later `@Observable` owner — `MailViewModel` in R3a — can read and write
/// through it without this type needing to know about observation itself.
///
/// Key shape: `domain.<accountID>.<domainID>.<field>`, with `accountID` and
/// `domainID` percent-escaped (see ``escapeKeyComponent(_:)``) before they go
/// into the key. Every getter defaults exactly the way the design spec calls
/// for (§4 State): `includeInAll` and `countInBadge` default ON, `hidden`
/// defaults OFF, `notify` defaults to `nil` ("use the global notification
/// setting" — see ``NotificationSettings``).
nonisolated enum DomainPreferences {
    // MARK: - Keys

    private static func key(_ field: String, accountID: String, domainID: String) -> String {
        "domain.\(escapeKeyComponent(accountID)).\(escapeKeyComponent(domainID)).\(field)"
    }

    /// Escapes `.` and `%` in a key component so `domain.<a>.<b>.<field>` can
    /// always be split back into exactly those four parts.
    ///
    /// Without this, an `accountID` is `Account.normalize(origin).absoluteString`
    /// (e.g. `https://mail.example`) — it contains dots — and same-host-prefix
    /// origins are realistic (`https://mail.example` vs `https://mail.example.org`).
    /// A plain `hasPrefix("domain.\(accountID).")` then matches the LONGER
    /// account's keys too (`domain.https://mail.example.org.dom.hidden` starts
    /// with `domain.https://mail.example.`), so ``hiddenDomainIDs(accountID:in:)``
    /// would read another account's hidden domains as this account's, with a
    /// mangled id, and ``purgeAll(accountID:from:)`` would delete them. Escaping
    /// `.` (the field separator) makes an escaped component never itself
    /// contain an unescaped `.`, so `domain.<escaped accountID>.` is safe as an
    /// exact prefix regardless of what either account id contains. `%` is
    /// escaped too because it is the escape marker itself. `domainID` gets the
    /// same treatment for the same reason — this module's own `MailDomain`
    /// fallback ids already contain dots (`"domain-name:<name>"`).
    static func escapeKeyComponent(_ raw: String) -> String {
        var result = ""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "%": result += "%25"
            case ".": result += "%2E"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Inverse of ``escapeKeyComponent(_:)``, for recovering a domain id out of
    /// a scanned key (``hiddenDomainIDs(accountID:in:)``). Any `%XX` that isn't
    /// valid hex is left as literal text rather than dropped or trapped — a key
    /// this function did not itself write must never crash the scan.
    private static func unescapeKeyComponent(_ escaped: String) -> String {
        var result = ""
        var index = escaped.startIndex
        while index < escaped.endIndex {
            let character = escaped[index]
            if character == "%",
               let hexEnd = escaped.index(index, offsetBy: 3, limitedBy: escaped.endIndex) {
                let hex = escaped[escaped.index(after: index)..<hexEnd]
                if let value = UInt8(hex, radix: 16) {
                    result.unicodeScalars.append(UnicodeScalar(value))
                    index = hexEnd
                    continue
                }
            }
            result.append(character)
            index = escaped.index(after: index)
        }
        return result
    }

    static func monogramKey(accountID: String, domainID: String) -> String {
        key("monogram", accountID: accountID, domainID: domainID)
    }

    /// `domain.<accountID>.<domainID>.tint` — the domain badge's optional
    /// colour override (a token name from ``AccountTintAssignment/tokenNames``).
    static func tintKey(accountID: String, domainID: String) -> String {
        key("tint", accountID: accountID, domainID: domainID)
    }

    /// `domain.<accountID>.<domainID>.defaultFrom` — the address (lowercased)
    /// a new message in this domain's scope starts from.
    static func defaultFromKey(accountID: String, domainID: String) -> String {
        key("defaultFrom", accountID: accountID, domainID: domainID)
    }

    static func includeInAllKey(accountID: String, domainID: String) -> String {
        key("includeInAll", accountID: accountID, domainID: domainID)
    }

    static func countInBadgeKey(accountID: String, domainID: String) -> String {
        key("countInBadge", accountID: accountID, domainID: domainID)
    }

    static func notifyKey(accountID: String, domainID: String) -> String {
        key("notify", accountID: accountID, domainID: domainID)
    }

    static func hiddenKey(accountID: String, domainID: String) -> String {
        key("hidden", accountID: accountID, domainID: domainID)
    }

    static func hiddenAtKey(accountID: String, domainID: String) -> String {
        key("hiddenAt", accountID: accountID, domainID: domainID)
    }

    /// The domain's name, captured at the moment it was hidden — the Hidden
    /// Domains list's (R9) fallback for a domain whose mailboxes have since
    /// left the account's cache, so that row can still show a real name
    /// instead of falling back to a raw id (a server `mailDomainID`, rarely
    /// human-legible).
    static func hiddenNameKey(accountID: String, domainID: String) -> String {
        key("hiddenName", accountID: accountID, domainID: domainID)
    }

    // MARK: - Monogram override

    /// The user's override, normalized (``DomainMonogram/normalizeOverride(_:)``).
    /// A stored value that no longer validates — e.g. edited outside the app, or
    /// left over from a build with different rules — reads back as `nil`, same
    /// as no override at all, rather than being handed to the UI unvalidated.
    static func monogramOverride(accountID: String, domainID: String, in defaults: UserDefaults) -> String? {
        guard let raw = defaults.string(forKey: monogramKey(accountID: accountID, domainID: domainID)) else {
            return nil
        }
        return DomainMonogram.normalizeOverride(raw)
    }

    /// `nil` clears the override. A value that fails validation is treated as
    /// clearing too, rather than being written malformed — the caller (a
    /// Settings text field in a later phase) can check ``DomainMonogram/normalizeOverride(_:)``
    /// itself first if it needs to reject keystrokes instead of silently no-op'ing.
    static func setMonogramOverride(_ raw: String?, accountID: String, domainID: String, in defaults: UserDefaults) {
        let key = monogramKey(accountID: accountID, domainID: domainID)
        guard let raw, let normalized = DomainMonogram.normalizeOverride(raw) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(normalized, forKey: key)
    }

    // MARK: - Tint override

    /// The domain badge's colour override, or `nil` = draw in the account's
    /// tint (the default, and the spec's §2 rule). A deliberate deviation from
    /// §2 ("only accounts get a hue"): with one account and many domains every
    /// badge would otherwise be the same colour. A stored value that is not
    /// one of the account-tint token names reads back as `nil` (unset).
    /// Resolve the colour actually drawn with
    /// ``DomainBadgeResolver/tintName(domainOverride:accountTintName:)``.
    static func tintOverride(accountID: String, domainID: String, in defaults: UserDefaults) -> String? {
        guard let raw = defaults.string(forKey: tintKey(accountID: accountID, domainID: domainID)),
              AccountTintAssignment.tokenNames.contains(raw) else { return nil }
        return raw
    }

    /// `nil` (or a name outside the token set) clears the override.
    static func setTintOverride(_ name: String?, accountID: String, domainID: String, in defaults: UserDefaults) {
        let key = tintKey(accountID: accountID, domainID: domainID)
        guard let name, AccountTintAssignment.tokenNames.contains(name) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(name, forKey: key)
    }

    // MARK: - Default From

    /// The stored default From address, lowercased, or `nil` ("Automatic").
    /// Whether it is still sendable is decided where the domain's addresses
    /// are known (``ComposeFrom/domainDefault(storedAddress:sendable:)``): a
    /// stale value reads as unset there.
    static func defaultFrom(accountID: String, domainID: String, in defaults: UserDefaults) -> String? {
        guard let raw = defaults.string(forKey: defaultFromKey(accountID: accountID, domainID: domainID)) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `nil` (or blank) returns the domain to "Automatic".
    static func setDefaultFrom(_ address: String?, accountID: String, domainID: String, in defaults: UserDefaults) {
        let key = defaultFromKey(accountID: accountID, domainID: domainID)
        let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
    }

    // MARK: - Toggles

    static func includeInAll(accountID: String, domainID: String, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: includeInAllKey(accountID: accountID, domainID: domainID)) as? Bool ?? true
    }

    static func setIncludeInAll(_ value: Bool, accountID: String, domainID: String, in defaults: UserDefaults) {
        defaults.set(value, forKey: includeInAllKey(accountID: accountID, domainID: domainID))
    }

    static func countInBadge(accountID: String, domainID: String, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: countInBadgeKey(accountID: accountID, domainID: domainID)) as? Bool ?? true
    }

    static func setCountInBadge(_ value: Bool, accountID: String, domainID: String, in defaults: UserDefaults) {
        defaults.set(value, forKey: countInBadgeKey(accountID: accountID, domainID: domainID))
    }

    /// `nil` means "use the global notification setting" (``NotificationSettings/newMailEnabled(in:)``).
    /// Only an explicit `true`/`false` overrides it for this one domain.
    static func notify(accountID: String, domainID: String, in defaults: UserDefaults) -> Bool? {
        defaults.object(forKey: notifyKey(accountID: accountID, domainID: domainID)) as? Bool
    }

    /// `nil` returns this domain to following the global setting.
    static func setNotify(_ value: Bool?, accountID: String, domainID: String, in defaults: UserDefaults) {
        let key = notifyKey(accountID: accountID, domainID: domainID)
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Hidden

    static func isHidden(accountID: String, domainID: String, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: hiddenKey(accountID: accountID, domainID: domainID)) as? Bool ?? false
    }

    /// `nil` while the domain has never been hidden (or was restored — see
    /// ``setHidden(_:accountID:domainID:in:name:now:)``).
    static func hiddenAt(accountID: String, domainID: String, in defaults: UserDefaults) -> Date? {
        defaults.object(forKey: hiddenAtKey(accountID: accountID, domainID: domainID)) as? Date
    }

    /// The name captured when the domain was hidden — `nil` once restored, or
    /// if it was hidden before this field existed.
    static func hiddenName(accountID: String, domainID: String, in defaults: UserDefaults) -> String? {
        defaults.string(forKey: hiddenNameKey(accountID: accountID, domainID: domainID))
    }

    /// Hiding stamps `hiddenAt` with `now` (a fresh hide is a fresh event, even
    /// for a domain hidden before and restored — the Hidden-domains list's
    /// "Hidden {date}" should reflect the LATEST hide, not the first) and
    /// records `name` (the caller's current best name for the domain, if it
    /// has one) as the Hidden Domains list's fallback once the domain's
    /// mailboxes are gone from the account's cache. Restoring (`false`) clears
    /// all three keys, so a restored domain reads identically to one that was
    /// never hidden.
    static func setHidden(
        _ hidden: Bool,
        accountID: String,
        domainID: String,
        in defaults: UserDefaults,
        name: String? = nil,
        now: Date = Date()
    ) {
        let hiddenKey = hiddenKey(accountID: accountID, domainID: domainID)
        let hiddenAtKey = hiddenAtKey(accountID: accountID, domainID: domainID)
        let hiddenNameKey = hiddenNameKey(accountID: accountID, domainID: domainID)
        if hidden {
            defaults.set(true, forKey: hiddenKey)
            defaults.set(now, forKey: hiddenAtKey)
            if let name { defaults.set(name, forKey: hiddenNameKey) }
        } else {
            defaults.removeObject(forKey: hiddenKey)
            defaults.removeObject(forKey: hiddenAtKey)
            defaults.removeObject(forKey: hiddenNameKey)
        }
    }

    /// Every domain id hidden for this account, for the Hidden Domains list.
    /// Scans the defaults' own key space (there is no separate index) rather
    /// than requiring a domain list up front — the caller already has one from
    /// `MailDomain.domains(from:)`, but this lets the Settings page populate
    /// the hidden list from stored prefs alone, including a domain that has
    /// since stopped appearing in the account's mailboxes.
    static func hiddenDomainIDs(accountID: String, in defaults: UserDefaults) -> Set<String> {
        let prefix = "domain.\(escapeKeyComponent(accountID))."
        let suffix = ".hidden"
        var ids: Set<String> = []
        for (key, value) in defaults.dictionaryRepresentation() {
            guard key.hasPrefix(prefix), key.hasSuffix(suffix) else { continue }
            guard let hidden = value as? Bool, hidden else { continue }
            let escapedDomainID = String(key.dropFirst(prefix.count).dropLast(suffix.count))
            let domainID = unescapeKeyComponent(escapedDomainID)
            guard !domainID.isEmpty else { continue }
            ids.insert(domainID)
        }
        return ids
    }

    /// Removes every `domain.<accountID>.*` key. Called from sign-out via
    /// `PreferenceHygiene.purgeAccount(_:from:)` (`AppEnvironment+SignIn.swift`)
    /// — a signed-out account's domain prefs are purged along with the rest
    /// of its Herald-only state.
    static func purgeAll(accountID: String, from defaults: UserDefaults) {
        let prefix = "domain.\(escapeKeyComponent(accountID))."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
