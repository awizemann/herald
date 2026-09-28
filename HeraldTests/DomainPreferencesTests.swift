import Foundation
import Testing

@testable import Herald

/// `DomainPreferences`: key shapes exactly as specced, defaults, override
/// precedence and the hidden-domain listing/purge helpers.
@Suite("Domain preferences", .scratchDefaults)
struct DomainPreferencesTests {
    private func makeDefaults() -> UserDefaults { ScratchDefaults.make() }

    // MARK: - Key shapes

    @Test("Keys follow domain.<accountID>.<domainID>.<field> exactly")
    func keyShapesAreExact() {
        #expect(DomainPreferences.monogramKey(accountID: "acct1", domainID: "dom1") == "domain.acct1.dom1.monogram")
        #expect(DomainPreferences.includeInAllKey(accountID: "acct1", domainID: "dom1") == "domain.acct1.dom1.includeInAll")
        #expect(DomainPreferences.countInBadgeKey(accountID: "acct1", domainID: "dom1") == "domain.acct1.dom1.countInBadge")
        #expect(DomainPreferences.notifyKey(accountID: "acct1", domainID: "dom1") == "domain.acct1.dom1.notify")
        #expect(DomainPreferences.hiddenKey(accountID: "acct1", domainID: "dom1") == "domain.acct1.dom1.hidden")
        #expect(DomainPreferences.hiddenAtKey(accountID: "acct1", domainID: "dom1") == "domain.acct1.dom1.hiddenAt")
        #expect(DomainPreferences.hiddenNameKey(accountID: "acct1", domainID: "dom1") == "domain.acct1.dom1.hiddenName")
    }

    /// `accountID`/`domainID` are percent-escaped (`.` → `%2E`, `%` → `%25`)
    /// before they go into the key, so a literal `.` inside either can never
    /// be mistaken for the `domain.<a>.<b>.<field>` separator. Pins the exact
    /// escaped form — a silent change to the escaping scheme would otherwise
    /// still pass every round-trip test while quietly breaking any key an
    /// older build already wrote to disk.
    @Test("accountID and domainID are percent-escaped in the key, not raw")
    func keysEscapeDotsAndPercent() {
        #expect(
            DomainPreferences.hiddenKey(accountID: "https://mail.x", domainID: "dom1")
                == "domain.https://mail%2Ex.dom1.hidden"
        )
        #expect(
            DomainPreferences.hiddenKey(accountID: "acct1", domainID: "domain-name:acme.co")
                == "domain.acct1.domain-name:acme%2Eco.hidden"
        )
        #expect(
            DomainPreferences.hiddenKey(accountID: "100%", domainID: "dom1")
                == "domain.100%25.dom1.hidden"
        )
    }

    // MARK: - Defaults

    @Test("Fresh defaults: includeInAll and countInBadge default ON, hidden defaults OFF, notify defaults to nil")
    func freshDefaults() {
        let defaults = makeDefaults()
        #expect(DomainPreferences.includeInAll(accountID: "a", domainID: "d", in: defaults) == true)
        #expect(DomainPreferences.countInBadge(accountID: "a", domainID: "d", in: defaults) == true)
        #expect(DomainPreferences.isHidden(accountID: "a", domainID: "d", in: defaults) == false)
        #expect(DomainPreferences.notify(accountID: "a", domainID: "d", in: defaults) == nil)
        #expect(DomainPreferences.hiddenAt(accountID: "a", domainID: "d", in: defaults) == nil)
        #expect(DomainPreferences.monogramOverride(accountID: "a", domainID: "d", in: defaults) == nil)
    }

    // MARK: - Toggles round-trip

    @Test("includeInAll/countInBadge round-trip and can be turned back on")
    func toggleRoundTrip() {
        let defaults = makeDefaults()
        DomainPreferences.setIncludeInAll(false, accountID: "a", domainID: "d", in: defaults)
        #expect(DomainPreferences.includeInAll(accountID: "a", domainID: "d", in: defaults) == false)
        DomainPreferences.setIncludeInAll(true, accountID: "a", domainID: "d", in: defaults)
        #expect(DomainPreferences.includeInAll(accountID: "a", domainID: "d", in: defaults) == true)

        DomainPreferences.setCountInBadge(false, accountID: "a", domainID: "d", in: defaults)
        #expect(DomainPreferences.countInBadge(accountID: "a", domainID: "d", in: defaults) == false)
    }

    @Test("notify distinguishes 'unset' (nil, follow global) from an explicit false")
    func notifyDistinguishesNilFromFalse() {
        let defaults = makeDefaults()
        #expect(DomainPreferences.notify(accountID: "a", domainID: "d", in: defaults) == nil)

        DomainPreferences.setNotify(false, accountID: "a", domainID: "d", in: defaults)
        #expect(DomainPreferences.notify(accountID: "a", domainID: "d", in: defaults) == false)

        DomainPreferences.setNotify(true, accountID: "a", domainID: "d", in: defaults)
        #expect(DomainPreferences.notify(accountID: "a", domainID: "d", in: defaults) == true)

        // Explicitly returning to nil must clear the stored key, not store nil.
        DomainPreferences.setNotify(nil, accountID: "a", domainID: "d", in: defaults)
        #expect(DomainPreferences.notify(accountID: "a", domainID: "d", in: defaults) == nil)
        #expect(defaults.object(forKey: DomainPreferences.notifyKey(accountID: "a", domainID: "d")) == nil)
    }

    // MARK: - Monogram override

    @Test("A valid monogram override round-trips normalized")
    func monogramOverrideRoundTrips() {
        let defaults = makeDefaults()
        DomainPreferences.setMonogramOverride(" nw ", accountID: "a", domainID: "d", in: defaults)
        #expect(DomainPreferences.monogramOverride(accountID: "a", domainID: "d", in: defaults) == "NW")
    }

    @Test("An invalid monogram override is not stored, and reading it back is nil")
    func invalidMonogramOverrideNotStored() {
        let defaults = makeDefaults()
        DomainPreferences.setMonogramOverride("!", accountID: "a", domainID: "d", in: defaults)
        #expect(DomainPreferences.monogramOverride(accountID: "a", domainID: "d", in: defaults) == nil)
    }

    @Test("A monogram value written directly to defaults (not through the setter) that no longer validates reads back nil")
    func staleMonogramFallsBackToNil() {
        let defaults = makeDefaults()
        // Simulates a value left by an older/different build with looser rules.
        defaults.set("TOOLONG", forKey: DomainPreferences.monogramKey(accountID: "a", domainID: "d"))
        #expect(DomainPreferences.monogramOverride(accountID: "a", domainID: "d", in: defaults) == nil)
    }

    // MARK: - Hidden / hiddenAt

    @Test("Hiding sets both hidden and hiddenAt; restoring clears both")
    func hideAndRestore() {
        let defaults = makeDefaults()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        DomainPreferences.setHidden(true, accountID: "a", domainID: "d", in: defaults, now: stamp)
        #expect(DomainPreferences.isHidden(accountID: "a", domainID: "d", in: defaults) == true)
        #expect(DomainPreferences.hiddenAt(accountID: "a", domainID: "d", in: defaults) == stamp)

        DomainPreferences.setHidden(false, accountID: "a", domainID: "d", in: defaults)
        #expect(DomainPreferences.isHidden(accountID: "a", domainID: "d", in: defaults) == false)
        #expect(DomainPreferences.hiddenAt(accountID: "a", domainID: "d", in: defaults) == nil)
    }

    @Test("Hiding again after a restore stamps a fresh hiddenAt, not the original")
    func rehidingStampsFreshDate() {
        let defaults = makeDefaults()
        let first = Date(timeIntervalSince1970: 1_000)
        let second = Date(timeIntervalSince1970: 2_000)

        DomainPreferences.setHidden(true, accountID: "a", domainID: "d", in: defaults, now: first)
        DomainPreferences.setHidden(false, accountID: "a", domainID: "d", in: defaults)
        DomainPreferences.setHidden(true, accountID: "a", domainID: "d", in: defaults, now: second)

        #expect(DomainPreferences.hiddenAt(accountID: "a", domainID: "d", in: defaults) == second)
    }

    /// R9: the name captured at hide time (the Hidden Domains list's fallback
    /// once the domain's mailboxes are gone from the account's cache) rounds
    /// through the same hide/restore lifecycle as `hidden`/`hiddenAt` — set
    /// together, cleared together.
    @Test("A hidden name is stored alongside hidden/hiddenAt and cleared on restore")
    func hiddenNameRoundTrips() {
        let defaults = makeDefaults()
        #expect(DomainPreferences.hiddenName(accountID: "a", domainID: "d", in: defaults) == nil)

        DomainPreferences.setHidden(true, accountID: "a", domainID: "d", in: defaults, name: "acme.co")
        #expect(DomainPreferences.hiddenName(accountID: "a", domainID: "d", in: defaults) == "acme.co")

        DomainPreferences.setHidden(false, accountID: "a", domainID: "d", in: defaults)
        #expect(DomainPreferences.hiddenName(accountID: "a", domainID: "d", in: defaults) == nil, "Restoring clears it too")
    }

    /// Hiding with no name (the caller had none to offer) must not write a
    /// stale empty string that would outrank the id fallback later.
    @Test("Hiding with no name leaves hiddenName unset")
    func hidingWithNoNameLeavesHiddenNameUnset() {
        let defaults = makeDefaults()
        DomainPreferences.setHidden(true, accountID: "a", domainID: "d", in: defaults)
        #expect(DomainPreferences.hiddenName(accountID: "a", domainID: "d", in: defaults) == nil)
    }

    // MARK: - hiddenDomainIDs(accountID:in:)

    @Test("hiddenDomainIDs lists only hidden domains for the given account, ignoring other accounts and other fields")
    func hiddenDomainIDsScopesByAccount() {
        let defaults = makeDefaults()
        DomainPreferences.setHidden(true, accountID: "acct1", domainID: "dom1", in: defaults)
        DomainPreferences.setHidden(true, accountID: "acct1", domainID: "dom2", in: defaults)
        DomainPreferences.setHidden(false, accountID: "acct1", domainID: "dom3", in: defaults) // never hidden
        DomainPreferences.setHidden(true, accountID: "acct2", domainID: "dom1", in: defaults) // different account
        DomainPreferences.setIncludeInAll(false, accountID: "acct1", domainID: "dom4", in: defaults) // unrelated field

        #expect(DomainPreferences.hiddenDomainIDs(accountID: "acct1", in: defaults) == ["dom1", "dom2"])
        #expect(DomainPreferences.hiddenDomainIDs(accountID: "acct2", in: defaults) == ["dom1"])
    }

    @Test("hiddenDomainIDs handles a domain id that itself contains dots (a fallback MailDomain id)")
    func hiddenDomainIDsHandlesDottedDomainID() {
        let defaults = makeDefaults()
        DomainPreferences.setHidden(true, accountID: "acct1", domainID: "domain-name:acme.co", in: defaults)

        #expect(DomainPreferences.hiddenDomainIDs(accountID: "acct1", in: defaults) == ["domain-name:acme.co"])
    }

    @Test("Restoring a domain removes it from hiddenDomainIDs")
    func restoringRemovesFromHiddenList() {
        let defaults = makeDefaults()
        DomainPreferences.setHidden(true, accountID: "acct1", domainID: "dom1", in: defaults)
        DomainPreferences.setHidden(false, accountID: "acct1", domainID: "dom1", in: defaults)

        #expect(DomainPreferences.hiddenDomainIDs(accountID: "acct1", in: defaults).isEmpty)
    }

    /// `accountID` is a normalized origin (`https://mail.example`) and contains
    /// dots. Without escaping, `hiddenDomainIDs(accountID: "https://mail.x")`'s
    /// naive `"domain.https://mail.x."` prefix ALSO matches
    /// `"https://mail.x.y"`'s keys (`domain.https://mail.x.y.<dom>.hidden`
    /// starts with that prefix too), reading the longer account's hidden
    /// domains as the shorter account's own — with a mangled id
    /// (`"y.<dom>"`). Same-host-prefix origins are realistic
    /// (mail.example vs mail.example.org).
    @Test("hiddenDomainIDs does not leak between accounts whose ids are prefix-related")
    func hiddenDomainIDsDoesNotLeakAcrossPrefixRelatedAccounts() {
        let defaults = makeDefaults()
        let shorter = "https://mail.x"
        let longer = "https://mail.x.y"

        DomainPreferences.setHidden(true, accountID: shorter, domainID: "dom1", in: defaults)
        DomainPreferences.setHidden(true, accountID: longer, domainID: "dom2", in: defaults)

        #expect(DomainPreferences.hiddenDomainIDs(accountID: shorter, in: defaults) == ["dom1"])
        #expect(DomainPreferences.hiddenDomainIDs(accountID: longer, in: defaults) == ["dom2"])
    }

    // MARK: - purgeAll(accountID:from:)

    /// Same collision as ``hiddenDomainIDsDoesNotLeakAcrossPrefixRelatedAccounts()``,
    /// but for deletion: a naive prefix match would have `purgeAll(accountID:
    /// "https://mail.x")` delete `"https://mail.x.y"`'s keys too.
    @Test("purgeAll does not touch a prefix-related account's keys")
    func purgeAllDoesNotTouchPrefixRelatedAccount() {
        let defaults = makeDefaults()
        let shorter = "https://mail.x"
        let longer = "https://mail.x.y"

        DomainPreferences.setHidden(true, accountID: shorter, domainID: "dom1", in: defaults)
        DomainPreferences.setHidden(true, accountID: longer, domainID: "dom2", in: defaults)

        DomainPreferences.purgeAll(accountID: shorter, from: defaults)

        #expect(DomainPreferences.isHidden(accountID: shorter, domainID: "dom1", in: defaults) == false)
        // The longer account's key must survive the shorter account's purge.
        #expect(DomainPreferences.isHidden(accountID: longer, domainID: "dom2", in: defaults) == true)
    }

    @Test("purgeAll removes every key for the given account and leaves other accounts untouched")
    func purgeAllScopesByAccount() {
        let defaults = makeDefaults()
        DomainPreferences.setIncludeInAll(false, accountID: "acct1", domainID: "dom1", in: defaults)
        DomainPreferences.setHidden(true, accountID: "acct1", domainID: "dom2", in: defaults)
        DomainPreferences.setMonogramOverride("NW", accountID: "acct1", domainID: "dom1", in: defaults)
        DomainPreferences.setIncludeInAll(false, accountID: "acct2", domainID: "dom1", in: defaults)

        DomainPreferences.purgeAll(accountID: "acct1", from: defaults)

        #expect(DomainPreferences.includeInAll(accountID: "acct1", domainID: "dom1", in: defaults) == true) // back to default
        #expect(DomainPreferences.isHidden(accountID: "acct1", domainID: "dom2", in: defaults) == false)
        #expect(DomainPreferences.monogramOverride(accountID: "acct1", domainID: "dom1", in: defaults) == nil)
        // Untouched: acct2's key survives.
        #expect(DomainPreferences.includeInAll(accountID: "acct2", domainID: "dom1", in: defaults) == false)
    }
}
