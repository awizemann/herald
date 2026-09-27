import Foundation
import Testing
@testable import HeraldKit

/// `MailDomain.domains(from:)`: grouping, ordering and the fallback path for a
/// mailbox with no usable address — the derivation must be total, never crash,
/// and never silently drop a mailbox.
@Suite struct MailDomainTests {
    static let epoch = Date(timeIntervalSince1970: 0)

    static func mailbox(
        id: String,
        address: String,
        mailDomainID: String,
        addresses: [MailboxAddress]? = nil
    ) -> Mailbox {
        Mailbox(
            id: id,
            address: address,
            addresses: addresses ?? [
                MailboxAddress(
                    id: "adr_\(id)",
                    mailboxID: id,
                    mailDomainID: mailDomainID,
                    address: address,
                    displayName: "",
                    receiveEnabled: true,
                    sendEnabled: true,
                    isPrimary: true
                ),
            ],
            displayName: "",
            isActive: true,
            accessLevel: .manager,
            createdAt: epoch,
            updatedAt: epoch
        )
    }

    // MARK: - domainName(of:)

    @Test("domainName(of:) returns the lowercased part after the last @")
    func domainNameLowercases() {
        #expect(MailDomain.domainName(of: "Sales@Acme.CO") == "acme.co")
    }

    @Test("domainName(of:) is nil with no @ or nothing after it")
    func domainNameNilCases() {
        #expect(MailDomain.domainName(of: "not-an-address") == nil)
        #expect(MailDomain.domainName(of: "sales@") == nil)
    }

    // MARK: - Grouping

    @Test("Mailboxes on the same mailDomainID group into one domain, id preserved")
    func groupsByDomainID() {
        let domains = MailDomain.domains(from: [
            Self.mailbox(id: "mbx_1", address: "help@acme.co", mailDomainID: "dom_1"),
            Self.mailbox(id: "mbx_2", address: "sales@acme.co", mailDomainID: "dom_1"),
            Self.mailbox(id: "mbx_3", address: "hi@other.test", mailDomainID: "dom_2"),
        ])

        #expect(domains.map(\.id) == ["dom_1", "dom_2"])
        #expect(domains.first { $0.id == "dom_1" }?.mailboxIDs == ["mbx_1", "mbx_2"])
        #expect(domains.first { $0.id == "dom_2" }?.mailboxIDs == ["mbx_3"])
    }

    @Test("Domains are sorted alphabetically by name; mailboxes within a domain by local part")
    func stableOrdering() {
        let domains = MailDomain.domains(from: [
            Self.mailbox(id: "mbx_z", address: "zed@zeta.test", mailDomainID: "dom_z"),
            Self.mailbox(id: "mbx_sales", address: "sales@acme.co", mailDomainID: "dom_a"),
            Self.mailbox(id: "mbx_help", address: "help@acme.co", mailDomainID: "dom_a"),
        ])

        #expect(domains.map(\.name) == ["acme.co", "zeta.test"])
        #expect(domains.first { $0.name == "acme.co" }?.mailboxIDs == ["mbx_help", "mbx_sales"])
    }

    // MARK: - Totality: a mailbox with no usable address must not vanish

    @Test("A mailbox with an empty mailDomainID falls back to a domain parsed from its address")
    func emptyDomainIDFallsBackToParsedAddress() {
        let empty = MailboxAddress(
            id: "adr", mailboxID: "mbx_1", mailDomainID: "", address: "help@acme.co",
            displayName: "", receiveEnabled: true, sendEnabled: true, isPrimary: true
        )
        let domains = MailDomain.domains(from: [
            Self.mailbox(id: "mbx_1", address: "help@acme.co", mailDomainID: "", addresses: [empty]),
        ])

        #expect(domains.count == 1)
        #expect(domains[0].name == "acme.co")
        #expect(domains[0].mailboxIDs == ["mbx_1"])
    }

    @Test("A mailbox that falls back by parsed address still merges with a peer on the real mailDomainID for that same name")
    func fallbackMailboxMergesByName() {
        let empty = MailboxAddress(
            id: "adr", mailboxID: "mbx_1", mailDomainID: "", address: "help@acme.co",
            displayName: "", receiveEnabled: true, sendEnabled: true, isPrimary: true
        )
        let fallbackMailbox = Self.mailbox(id: "mbx_1", address: "help@acme.co", mailDomainID: "", addresses: [empty])
        let normalMailbox = Self.mailbox(id: "mbx_2", address: "sales@acme.co", mailDomainID: "dom_1")

        let domains = MailDomain.domains(from: [fallbackMailbox, normalMailbox])

        // Different bucket keys ("domain-name:acme.co" vs "dom_1") by design —
        // a fallback never claims the server's real id — but both still read as
        // the "acme.co" domain and neither mailbox is dropped.
        #expect(domains.map(\.name).sorted() == ["acme.co", "acme.co"])
        #expect(Set(domains.flatMap(\.mailboxIDs)) == ["mbx_1", "mbx_2"])
    }

    @Test("A mailbox with no mailDomainID and no parseable address groups under the fallback id/name, not dropped")
    func totallyUnparseableMailboxUsesFallback() {
        let empty = MailboxAddress(
            id: "adr", mailboxID: "mbx_1", mailDomainID: "", address: "",
            displayName: "", receiveEnabled: true, sendEnabled: true, isPrimary: true
        )
        let mailbox = Mailbox(
            id: "mbx_1", address: "", addresses: [empty], displayName: "",
            isActive: true, accessLevel: nil, createdAt: Self.epoch, updatedAt: Self.epoch
        )

        let domains = MailDomain.domains(from: [mailbox])

        #expect(domains.count == 1)
        #expect(domains[0].id == MailDomain.fallbackID)
        #expect(domains[0].name == MailDomain.fallbackName)
        #expect(domains[0].mailboxIDs == ["mbx_1"])
    }

    @Test("A mailbox with a totally empty addresses array (no items at all) still groups by its own convenience address")
    func noAddressesArrayFallsBackToMailboxAddress() {
        let mailbox = Mailbox(
            id: "mbx_1", address: "team@acme.co", addresses: [], displayName: "",
            isActive: true, accessLevel: nil, createdAt: Self.epoch, updatedAt: Self.epoch
        )

        let domains = MailDomain.domains(from: [mailbox])

        #expect(domains.count == 1)
        #expect(domains[0].name == "acme.co")
        #expect(domains[0].mailboxIDs == ["mbx_1"])
    }

    @Test("An empty mailbox list produces no domains")
    func emptyInput() {
        #expect(MailDomain.domains(from: []).isEmpty)
    }
}
