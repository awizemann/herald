import Foundation
import HeraldKit
import Testing
@testable import Herald

/// `DomainBadgeResolver`: which mailbox resolves to which domain badge — the
/// monogram (with clash promotion and an override) and the owning account's
/// tint (with its own override), plus the `UserDefaults`-reading convenience
/// every SwiftUI call site actually uses.
@Suite("Domain badge resolver", .scratchDefaults)
struct DomainBadgeResolverTests {
    static let epoch = Date(timeIntervalSince1970: 0)

    static func mailbox(id: String, address: String, mailDomainID: String) -> Mailbox {
        Mailbox(
            id: id,
            address: address,
            addresses: [
                MailboxAddress(
                    id: "adr_\(id)", mailboxID: id, mailDomainID: mailDomainID, address: address,
                    displayName: "", receiveEnabled: true, sendEnabled: true, isPrimary: true
                ),
            ],
            displayName: "", isActive: true, accessLevel: .manager, createdAt: epoch, updatedAt: epoch
        )
    }

    private func makeDefaults() -> UserDefaults { ScratchDefaults.make() }

    // MARK: - The pure half

    @Test("Resolves the domain a mailbox belongs to, with the hash-default tint")
    func resolvesMailboxToItsDomain() {
        let domains = MailDomain.domains(from: [
            Self.mailbox(id: "mbx1", address: "sales@acme.co", mailDomainID: "dom-acme"),
        ])
        let info = DomainBadgeResolver.resolve(
            mailboxID: "mbx1", domains: domains, monogramOverrides: [:],
            accountID: "https://mail.acme.co", tintOverride: nil
        )
        #expect(info?.monogram == "AC")
        #expect(info?.domainName == "acme.co")
        #expect(info?.tintName == AccountTintAssignment.defaultToken(forAccountID: "https://mail.acme.co"))
    }

    @Test("A mailbox id in no domain resolves to nil rather than a fabricated badge")
    func unknownMailboxIsNil() {
        let info = DomainBadgeResolver.resolve(
            mailboxID: "ghost", domains: [], monogramOverrides: [:],
            accountID: "acct", tintOverride: nil
        )
        #expect(info == nil)
    }

    @Test("A clash across two domains in the account promotes both to three letters")
    func clashPromotesToThreeLetters() {
        let mailboxes = [
            Self.mailbox(id: "mbx1", address: "editor@northwind.io", mailDomainID: "dom-north"),
            Self.mailbox(id: "mbx2", address: "hello@notion.io", mailDomainID: "dom-not"),
        ]
        let domains = MailDomain.domains(from: mailboxes)
        let north = DomainBadgeResolver.resolve(
            mailboxID: "mbx1", domains: domains, monogramOverrides: [:], accountID: "acct", tintOverride: nil
        )
        let notion = DomainBadgeResolver.resolve(
            mailboxID: "mbx2", domains: domains, monogramOverrides: [:], accountID: "acct", tintOverride: nil
        )
        #expect(north?.monogram == "NOR")
        #expect(notion?.monogram == "NOT")
    }

    @Test("A monogram override wins over the derived clash-free letters")
    func monogramOverrideWins() {
        let domains = MailDomain.domains(from: [
            Self.mailbox(id: "mbx1", address: "sales@acme.co", mailDomainID: "dom-acme"),
        ])
        let info = DomainBadgeResolver.resolve(
            mailboxID: "mbx1", domains: domains, monogramOverrides: ["dom-acme": "ACM"],
            accountID: "acct", tintOverride: nil
        )
        #expect(info?.monogram == "ACM")
    }

    @Test("A tint override wins over the hash default")
    func tintOverrideWins() {
        let domains = MailDomain.domains(from: [
            Self.mailbox(id: "mbx1", address: "sales@acme.co", mailDomainID: "dom-acme"),
        ])
        let info = DomainBadgeResolver.resolve(
            mailboxID: "mbx1", domains: domains, monogramOverrides: [:],
            accountID: "acct", tintOverride: "rose"
        )
        #expect(info?.tintName == "rose")
    }

    // MARK: - The `UserDefaults`-reading convenience

    @Test("The convenience reads the monogram and tint overrides straight out of UserDefaults")
    func convenienceReadsStoredOverrides() {
        let defaults = makeDefaults()
        let mailboxes = [Self.mailbox(id: "mbx1", address: "sales@acme.co", mailDomainID: "dom-acme")]
        let domains = MailDomain.domains(from: mailboxes)
        let domainID = domains[0].id
        DomainPreferences.setMonogramOverride("SLS", accountID: "acct", domainID: domainID, in: defaults)
        defaults.set("plum", forKey: AccountTintAssignment.storageKey(accountID: "acct"))

        let info = DomainBadgeResolver.resolve(mailboxID: "mbx1", mailboxes: mailboxes, accountID: "acct", in: defaults)
        #expect(info?.monogram == "SLS")
        #expect(info?.tintName == "plum")
    }

    @Test("With no stored overrides the convenience matches the pure derivation")
    func convenienceWithNoOverridesMatchesDerivation() {
        let defaults = makeDefaults()
        let mailboxes = [Self.mailbox(id: "mbx1", address: "sales@acme.co", mailDomainID: "dom-acme")]
        let info = DomainBadgeResolver.resolve(mailboxID: "mbx1", mailboxes: mailboxes, accountID: "acct", in: defaults)
        #expect(info?.monogram == "AC")
        #expect(info?.tintName == AccountTintAssignment.defaultToken(forAccountID: "acct"))
    }
}
