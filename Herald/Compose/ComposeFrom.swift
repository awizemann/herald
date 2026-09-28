import Foundation
import HeraldKit

/// One address the From picker can show: every address of every mailbox the
/// composer was handed, sendable or not. A non-sendable one is listed (the
/// picker draws it dimmed, "Can't send") but ``ComposeViewModel/selectFrom(_:)``
/// refuses it.
nonisolated struct FromCandidate: Identifiable, Hashable, Sendable {
    /// Lowercased address: two mailboxes never share an address, and the picker
    /// needs a key that does not care how the server capitalised it.
    var id: String { address.lowercased() }
    let address: String
    /// The address's own display name, else the mailbox's; may be empty.
    let displayName: String
    /// The mailbox this address sends from — set on the draft TOGETHER with
    /// the address, never one without the other.
    let mailboxID: String
    /// The domain part of ``address``, lowercased — the group it is listed under.
    let domain: String
    /// `MailboxAddress.sendEnabled` (the spec's `canSend`).
    let canSend: Bool
    let isPrimary: Bool
}

/// One domain's section of the From picker.
nonisolated struct FromCandidateGroup: Identifiable, Hashable, Sendable {
    var id: String { domain }
    let domain: String
    let candidates: [FromCandidate]
}

/// The pure From rules: what the picker lists, and which address a new
/// message or a reply starts from. Static and payload-only so every rule is
/// assertable without a window or a view-model.
nonisolated enum ComposeFrom {
    /// Every address of `mailboxes`, deduplicated case-insensitively (first
    /// mailbox wins), in the mailboxes' order.
    static func candidates(from mailboxes: [Mailbox]) -> [FromCandidate] {
        var seen: Set<String> = []
        var result: [FromCandidate] = []
        for mailbox in mailboxes {
            for address in mailbox.addresses where !address.address.isEmpty {
                let key = address.address.lowercased()
                guard seen.insert(key).inserted else { continue }
                result.append(FromCandidate(
                    address: address.address,
                    displayName: address.displayName.isEmpty ? mailbox.displayName : address.displayName,
                    mailboxID: mailbox.id,
                    domain: MailDomain.domainName(of: address.address) ?? MailDomain.fallbackName,
                    canSend: address.sendEnabled,
                    isPrimary: address.isPrimary
                ))
            }
        }
        return result
    }

    /// The picker's sections: grouped by domain, domains alphabetical, the
    /// primary address first within a domain and the rest alphabetical.
    /// `filter` matches address or display name, case-insensitively; a domain
    /// with no match is left out.
    static func groups(_ candidates: [FromCandidate], filter: String) -> [FromCandidateGroup] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = needle.isEmpty ? candidates : candidates.filter {
            $0.address.localizedCaseInsensitiveContains(needle)
                || $0.displayName.localizedCaseInsensitiveContains(needle)
        }
        return Dictionary(grouping: matching, by: \.domain)
            .map { domain, members in
                FromCandidateGroup(domain: domain, candidates: members.sorted { lhs, rhs in
                    if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
                    return lhs.address.lowercased() < rhs.address.lowercased()
                })
            }
            .sorted { $0.domain < $1.domain }
    }

    /// The account's primary address: the first mailbox's primary sendable
    /// address (``Mailbox/sendableAddresses`` sorts primary first), else the
    /// first sendable address anywhere. `mailboxes` must already be the ones
    /// the user can compose from (enabled, not in a hidden domain), in the
    /// mailbox list's order.
    static func accountPrimary(in mailboxes: [Mailbox]) -> MailboxAddress? {
        mailboxes.lazy.compactMap { $0.sendableAddresses.first }.first
    }

    /// Where a new message starts: the sidebar scope's mailbox (a mailbox
    /// scope → its sendable address; a domain scope → the account primary when
    /// it is in that domain, else the domain's first sendable address), then
    /// the account primary. `nil` when nothing in `mailboxes` can send.
    static func defaultAddress(
        scope: MailViewModel.Scope,
        mailboxes: [Mailbox],
        domains: [MailDomain]
    ) -> MailboxAddress? {
        let primary = accountPrimary(in: mailboxes)
        switch scope {
        case .mailbox(let id):
            if let address = mailboxes.first(where: { $0.id == id })?.sendableAddresses.first {
                return address
            }
        case .domain(let id):
            let inDomain = Set(domains.first { $0.id == id }?.mailboxIDs ?? [])
            if let primary, inDomain.contains(primary.mailboxID) { return primary }
            if let first = mailboxes.lazy
                .filter({ inDomain.contains($0.id) })
                .compactMap({ $0.sendableAddresses.first })
                .first {
                return first
            }
        case .allDomains:
            break
        }
        return primary
    }

    /// The address a reply (or forward) of `message` goes out from: the one
    /// of `mailbox`'s sendable addresses the original was actually sent to —
    /// Delivered-To first (the copy this mailbox received), then To, then Cc,
    /// case-insensitively. For our own sent message, the address it was sent
    /// FROM. `nil` when none match; the caller falls back to the mailbox's
    /// primary.
    static func replyAddress(for message: MessageDetail, in mailbox: Mailbox) -> MailboxAddress? {
        let sendable = mailbox.sendableAddresses
        var probes: [String] = []
        if message.summary.direction == .outbound { probes.append(message.summary.fromAddress) }
        if let delivered = message.deliveredToAddress { probes.append(delivered) }
        probes += message.summary.to + message.cc
        for probe in probes {
            let key = bareAddress(probe).lowercased()
            if let match = sendable.first(where: { $0.address.lowercased() == key }) { return match }
        }
        return nil
    }

    /// `"Name <a@b>"` → `"a@b"`; anything else trimmed as is.
    static func bareAddress(_ raw: String) -> String {
        if let open = raw.lastIndex(of: "<"), let close = raw.lastIndex(of: ">"), open < close {
            return String(raw[raw.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }
}
