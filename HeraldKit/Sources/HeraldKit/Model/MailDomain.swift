import Foundation

/// A domain, derived — never fetched — from the mailboxes the account can see.
///
/// The API pins `Mailbox.addresses` to `minItems 1, maxItems 1` (see
/// `HQBase Mail API v1 Contract`), so in the common case each mailbox belongs to
/// exactly one domain and this is a straight group-by on `mailDomainID`. The two
/// fallbacks in ``domains(from:)`` only guard a cache row that has not caught up
/// with that contract — `MailboxAddress.init(from:)` is a TOTAL decode that
/// defaults every field to "" rather than throwing (see its doc comment), so an
/// old or malformed cache blob can hand this function a mailbox with no usable
/// address at all. Even then a mailbox must not crash the app or silently vanish
/// from every domain-scoped view (sidebar, "All domains", counts).
public nonisolated struct MailDomain: Sendable, Hashable, Identifiable {
    /// `mailDomainID` from the server, or a synthesized id when none was
    /// usable — see ``domains(from:)``.
    public let id: String
    /// The domain part of the address after `@`, lowercased.
    public let name: String
    /// Every mailbox that belongs to this domain, ordered deterministically:
    /// alphabetically by local part, then by mailbox id as a tie-break.
    public let mailboxIDs: [String]

    public init(id: String, name: String, mailboxIDs: [String]) {
        self.id = id
        self.name = name
        self.mailboxIDs = mailboxIDs
    }
}

// `nonisolated` here matches the primary declaration above: under
// default-MainActor isolation, a member in a SEPARATE extension does not
// inherit a type's own `nonisolated`, so without this every `static func`
// below defaults to MainActor and cannot be called synchronously from a
// nonisolated context (caught by the R6 reading pane's `DomainBadgeResolver`,
// the first real, non-test caller of `domains(from:)`).
nonisolated extension MailDomain {
    /// The id/name a mailbox with no usable `mailDomainID` and no parseable
    /// address groups under, so it still shows up somewhere rather than being
    /// dropped. Never produced by a real server response — every address the
    /// API returns carries a `mailDomainID` — this only guards a cache row a
    /// future shape change left fully defaulted.
    public static let fallbackID = "unassigned"
    public static let fallbackName = "(no domain)"

    /// The part after the last `@`, lowercased. `nil` when the address has no
    /// `@` or nothing follows it.
    ///
    /// Replaces the identical, address-target-only `domainName(of:)` that used
    /// to live on `SignatureSettingsModel` (Herald app target) — that type calls
    /// into this one now rather than duplicating the parse.
    public static func domainName(of address: String) -> String? {
        guard let at = address.lastIndex(of: "@") else { return nil }
        let domain = address[address.index(after: at)...]
        return domain.isEmpty ? nil : domain.lowercased()
    }

    /// Pure, total derivation. Every mailbox lands in exactly one domain, in a
    /// stable order (domains alphabetical by name; mailboxes within a domain by
    /// local part) so sidebar/settings rendering never needs its own sort.
    public static func domains(from mailboxes: [Mailbox]) -> [MailDomain] {
        struct Bucket {
            var name: String
            var members: [(localPart: String, mailboxID: String)] = []
        }

        var buckets: [String: Bucket] = [:]
        var order: [String] = []

        for mailbox in mailboxes {
            let (domainID, domainName) = groupingKey(for: mailbox)
            if buckets[domainID] == nil {
                buckets[domainID] = Bucket(name: domainName)
                order.append(domainID)
            }
            buckets[domainID]?.members.append((localPart(of: mailbox), mailbox.id))
        }

        return order
            .compactMap { id -> MailDomain? in
                guard let bucket = buckets[id] else { return nil }
                let orderedIDs = bucket.members
                    .sorted { lhs, rhs in
                        if lhs.localPart != rhs.localPart {
                            return lhs.localPart.localizedStandardCompare(rhs.localPart) == .orderedAscending
                        }
                        return lhs.mailboxID < rhs.mailboxID
                    }
                    .map(\.mailboxID)
                return MailDomain(id: id, name: bucket.name, mailboxIDs: orderedIDs)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The (id, name) a mailbox groups under.
    ///
    /// 1. The primary address's `mailDomainID`, when present — the server-issued,
    ///    stable identity, paired with the domain parsed from that same address.
    /// 2. Otherwise a domain parsed from whichever address string IS present
    ///    (`addresses.first?.address`, else the mailbox's own convenience
    ///    `address`), keyed by name so it still merges with a peer mailbox on
    ///    the same domain rather than getting a one-off bucket.
    /// 3. ``fallbackID``/``fallbackName`` only when nothing at all is parseable.
    private static func groupingKey(for mailbox: Mailbox) -> (id: String, name: String) {
        if let primary = mailbox.addresses.first, !primary.mailDomainID.isEmpty {
            let name = domainName(of: primary.address) ?? primary.mailDomainID.lowercased()
            return (primary.mailDomainID, name)
        }
        let fallbackAddress = mailbox.addresses.first?.address.isEmpty == false
            ? mailbox.addresses.first!.address
            : mailbox.address
        if let name = domainName(of: fallbackAddress) {
            return ("domain-name:\(name)", name)
        }
        return (fallbackID, fallbackName)
    }

    private static func localPart(of mailbox: Mailbox) -> String {
        let address = mailbox.addresses.first?.address.isEmpty == false
            ? mailbox.addresses.first!.address
            : mailbox.address
        guard let at = address.firstIndex(of: "@") else { return address }
        return String(address[address.startIndex..<at])
    }
}
