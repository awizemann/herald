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

    // MARK: - purgeAll(accountID:from:)

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
