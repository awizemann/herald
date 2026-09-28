import Foundation
import HeraldKit
import Testing
@testable import Herald

/// The optional per-domain badge colour (Alan, 2026-09-28 — a deliberate
/// deviation from handoff §2's "only accounts get a hue"): stored at
/// `domain.<accountID>.<domainID>.tint`, resolved everywhere by ONE rule —
/// domain override ?? account tint.
@Suite("Domain tint override", .scratchDefaults)
struct DomainTintTests {
    static let account = "https://mail.acme.co"
    static let mailboxes = [
        DomainBadgeResolverTests.mailbox(id: "mbSales", address: "sales@acme.co", mailDomainID: "dom-acme"),
        DomainBadgeResolverTests.mailbox(id: "mbOps", address: "ops@north.io", mailDomainID: "dom-north"),
    ]

    private func accountTintName() -> String {
        AccountTintAssignment.defaultToken(forAccountID: Self.account)
    }

    /// A token that is NOT the account's default, so a test cannot pass by
    /// the override silently falling through to the account tint.
    private func otherTint(than name: String) -> String {
        AccountTintAssignment.tokenNames.first { $0 != name }!
    }

    @Test("Pref key is domain.<escaped account>.<escaped domain>.tint")
    func keyFormat() {
        #expect(DomainPreferences.tintKey(accountID: "https://mail.x", domainID: "dom.1")
            == "domain.https://mail%2Ex.dom%2E1.tint")
    }

    @Test("The rule: a valid override wins; nil or an unknown name is the account tint")
    func rule() {
        #expect(DomainBadgeResolver.tintName(domainOverride: "plum", accountTintName: "moss") == "plum")
        #expect(DomainBadgeResolver.tintName(domainOverride: nil, accountTintName: "moss") == "moss")
        #expect(DomainBadgeResolver.tintName(domainOverride: "chartreuse", accountTintName: "moss") == "moss")
        let moss = MailTheme.accountTint(named: "moss")!
        #expect(DomainBadgeResolver.tint(domainOverride: "rose", accountTint: moss).name == "rose")
        #expect(DomainBadgeResolver.tint(domainOverride: nil, accountTint: moss).name == "moss")
    }

    @Test("A stored invalid value reads back as unset")
    func invalidStoredIsUnset() {
        let defaults = ScratchDefaults.make()
        defaults.set("chartreuse", forKey: DomainPreferences.tintKey(accountID: Self.account, domainID: "dom-acme"))
        #expect(DomainPreferences.tintOverride(accountID: Self.account, domainID: "dom-acme", in: defaults) == nil)
        let info = DomainBadgeResolver.resolve(
            mailboxID: "mbSales", mailboxes: Self.mailboxes, accountID: Self.account, in: defaults
        )
        #expect(info?.tintName == accountTintName())
    }

    @Test("Two domains in one account can draw different colours")
    func twoDomainsDiffer() {
        let defaults = ScratchDefaults.make()
        let override = otherTint(than: accountTintName())
        DomainPreferences.setTintOverride(override, accountID: Self.account, domainID: "dom-acme", in: defaults)

        let acme = DomainBadgeResolver.resolve(
            mailboxID: "mbSales", mailboxes: Self.mailboxes, accountID: Self.account, in: defaults
        )
        let north = DomainBadgeResolver.resolve(
            mailboxID: "mbOps", mailboxes: Self.mailboxes, accountID: Self.account, in: defaults
        )
        #expect(acme?.tintName == override)
        #expect(north?.tintName == accountTintName())

        // The observed variant (reading pane, compose From) follows the same rule.
        let observed = DomainBadgeResolver.resolve(
            mailboxID: "mbSales", mailboxes: Self.mailboxes, accountID: Self.account, tintName: "moss", in: defaults
        )
        #expect(observed?.tintName == override)
        let observedNorth = DomainBadgeResolver.resolve(
            mailboxID: "mbOps", mailboxes: Self.mailboxes, accountID: Self.account, tintName: "moss", in: defaults
        )
        #expect(observedNorth?.tintName == "moss")
    }

    @Test("Reset (nil) clears the override; an unknown name clears instead of storing")
    func resetClears() {
        let defaults = ScratchDefaults.make()
        let key = DomainPreferences.tintKey(accountID: Self.account, domainID: "dom-acme")
        DomainPreferences.setTintOverride("plum", accountID: Self.account, domainID: "dom-acme", in: defaults)
        #expect(defaults.string(forKey: key) == "plum")
        DomainPreferences.setTintOverride(nil, accountID: Self.account, domainID: "dom-acme", in: defaults)
        #expect(defaults.object(forKey: key) == nil)
        DomainPreferences.setTintOverride("plum", accountID: Self.account, domainID: "dom-acme", in: defaults)
        DomainPreferences.setTintOverride("chartreuse", accountID: Self.account, domainID: "dom-acme", in: defaults)
        #expect(defaults.object(forKey: key) == nil)
    }

    @Test("Row attribution carries the domain override for each of its mailboxes")
    func rowAttribution() {
        let index = ListColumn.AttributionIndex.make(
            level: .init(scope: .allDomains), mailboxes: Self.mailboxes,
            domains: MailDomain.domains(from: Self.mailboxes), monogramOverrides: [:],
            tintOverrides: ["dom-acme": "plum"]
        )
        #expect(index.attribution(forMailbox: "mbSales").tintOverride == "plum")
        #expect(index.attribution(forMailbox: "mbOps").tintOverride == nil)
    }

    @Test("Sign-out hygiene removes the domain tint with the rest of the account's prefs")
    func purgedWithAccount() {
        let defaults = ScratchDefaults.make()
        DomainPreferences.setTintOverride("plum", accountID: Self.account, domainID: "dom-acme", in: defaults)
        PreferenceHygiene.purgeAccount(Self.account, from: defaults)
        #expect(DomainPreferences.tintOverride(accountID: Self.account, domainID: "dom-acme", in: defaults) == nil)
    }
}
