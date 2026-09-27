import Foundation
import HeraldKit

/// The badge letters a domain draws in the sidebar, row attribution and
/// Settings — pure derivation from a domain name, with clash resolution across
/// every domain in one account and a user override that always wins.
///
/// Pure and `nonisolated` for the same reason as ``MailboxColorAssignment``: the
/// assignment must be identical every launch, which is only assertable
/// off-screen.
nonisolated enum DomainMonogram {
    /// Two letters from the domain's first DNS label, uppercased
    /// (`acme.co` → `AC`). A label shorter than two characters (rare, but not
    /// impossible — a single-letter label is valid DNS) yields fewer letters
    /// rather than a fabricated pad; the tint wash and the full domain name
    /// shown alongside are what make a one-letter badge legible.
    static func derive(from domainName: String, length: Int = 2) -> String {
        let firstLabel = domainName.split(separator: ".", maxSplits: 1).first.map(String.init) ?? domainName
        return String(firstLabel.uppercased().prefix(length))
    }

    /// 2–3 letters, trimmed and uppercased. `nil` for anything else (wrong
    /// length, or a character that is not a letter/digit — punctuation would
    /// not read as a monogram) so a rejected entry is treated exactly like no
    /// override rather than being stored malformed.
    static func normalizeOverride(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard (2...3).contains(trimmed.count) else { return nil }
        guard trimmed.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return trimmed
    }

    /// Assigns every domain in one account its badge text.
    ///
    /// - A domain with a valid override (``normalizeOverride(_:)``) always gets
    ///   it — overrides are never promoted or demoted for a clash; that is the
    ///   user's explicit choice.
    /// - Every other domain is derived at two letters, UNLESS two or more of
    ///   them share the same two-letter derivation, in which case the whole
    ///   group is promoted to three letters (`NOR`/`NOT`).
    /// - If a promoted group still collides at three letters (e.g. "notion.io"
    ///   and "notable.io" both derive "NOT"), both keep the shared three-letter
    ///   text. The design's uniqueness guarantee stops at three letters; the
    ///   badge is a secondary cue next to the tint wash and the full domain
    ///   name shown alongside it (never the only thing distinguishing two
    ///   domains), so an accepted collision here does not lose information.
    static func assign(
        domains: [MailDomain],
        overrides: [MailDomain.ID: String] = [:]
    ) -> [MailDomain.ID: String] {
        var result: [MailDomain.ID: String] = [:]
        var derived: [MailDomain] = []

        for domain in domains {
            if let raw = overrides[domain.id], let normalized = normalizeOverride(raw) {
                result[domain.id] = normalized
            } else {
                derived.append(domain)
            }
        }

        let twoLetterGroups = Dictionary(grouping: derived) { derive(from: $0.name, length: 2) }
        for domain in derived {
            let twoLetter = derive(from: domain.name, length: 2)
            let clashes = (twoLetterGroups[twoLetter]?.count ?? 0) > 1
            result[domain.id] = clashes ? derive(from: domain.name, length: 3) : twoLetter
        }

        return result
    }
}
