import Foundation
import HeraldKit
import SwiftUI

/// Resolves which mailbox a badge is drawn for into what ``DomainBadge`` needs:
/// the monogram (``DomainMonogram``) and the owning account's tint token
/// (``AccountTintAssignment``).
///
/// Deliberately NOT a `MailViewModel` property (R3a is concurrently reworking
/// its state, and this is additive, read-only derivation a view can call for
/// itself): every call site hands in the mailboxes and preferences it already
/// has. The two-phase split — a pure function over already-read overrides, and
/// a convenience that reads `UserDefaults` itself — mirrors
/// ``DomainPreferences``/``AccountTintAssignment``: the clash/override RULES
/// are assertable without a `UserDefaults` in play at all.
nonisolated enum DomainBadgeResolver {
    /// What one mailbox's badge draws, plus the domain name for a caller that
    /// wants to show it alongside (e.g. a tooltip or accessibility label).
    struct Info: Sendable, Hashable {
        let monogram: String
        let domainName: String
        /// A token name from ``MailTheme/accountTints``, resolved by
        /// ``AccountTintAssignment``. Kept as the NAME (not a `Color`) so this
        /// type stays comparable/testable without pulling `MailTheme` colour
        /// resolution into the test; a caller looks it up with
        /// ``MailTheme/accountTint(named:)`` when it actually draws.
        let tintName: String
    }

    /// The pure half. `domains` is whatever the caller already derived with
    /// `MailDomain.domains(from:)` — resolving it again per call for every
    /// mailbox drawn on screen would be wasted work in a view that draws many
    /// badges at once (the sidebar, a domain's mailbox table).
    static func resolve(
        mailboxID: String,
        domains: [MailDomain],
        monogramOverrides: [MailDomain.ID: String],
        accountID: String,
        tintOverride: String?
    ) -> Info? {
        guard let domain = domains.first(where: { $0.mailboxIDs.contains(mailboxID) }) else { return nil }
        let monograms = DomainMonogram.assign(domains: domains, overrides: monogramOverrides)
        // `assign(domains:overrides:)` always returns an entry for every domain
        // it was handed; the fallback only guards a future change to that
        // contract from silently dropping the badge instead of failing a test.
        let monogram = monograms[domain.id] ?? DomainMonogram.derive(from: domain.name)
        let tintName = AccountTintAssignment.token(forAccountID: accountID, override: tintOverride)
        return Info(monogram: monogram, domainName: domain.name, tintName: tintName)
    }

    /// The convenience most SwiftUI call sites want: derives the domains from
    /// `mailboxes` and reads both overrides out of `defaults` itself. One
    /// mailbox at a time — the reading pane's only caller today — so this
    /// re-derivation cost is one message header, not a whole list.
    static func resolve(
        mailboxID: String,
        mailboxes: [Mailbox],
        accountID: String,
        in defaults: UserDefaults
    ) -> Info? {
        let domains = MailDomain.domains(from: mailboxes)
        let tintOverride = defaults.string(forKey: AccountTintAssignment.storageKey(accountID: accountID))
        return resolve(
            mailboxID: mailboxID, domains: domains,
            monogramOverrides: monogramOverrides(for: domains, accountID: accountID, in: defaults),
            accountID: accountID, tintOverride: tintOverride
        )
    }

    /// The OBSERVED variant: the caller hands in the tint name it read through
    /// `AppEnvironment.accountTintName(for:)` (observable — it repaints when
    /// Settings › Account changes the colour) instead of this type reading the
    /// override out of `UserDefaults`, which nothing observes. Pass
    /// `environment.domainPreferencesObserved()` as `defaults` so a monogram
    /// override repaints too.
    static func resolve(
        mailboxID: String,
        mailboxes: [Mailbox],
        accountID: String,
        tintName: String,
        in defaults: UserDefaults
    ) -> Info? {
        let domains = MailDomain.domains(from: mailboxes)
        guard let resolved = resolve(
            mailboxID: mailboxID, domains: domains,
            monogramOverrides: monogramOverrides(for: domains, accountID: accountID, in: defaults),
            accountID: accountID, tintOverride: nil
        ) else { return nil }
        return Info(monogram: resolved.monogram, domainName: resolved.domainName, tintName: tintName)
    }

    /// Every domain's stored monogram override, for ``DomainMonogram/assign(domains:overrides:)``.
    static func monogramOverrides(
        for domains: [MailDomain], accountID: String, in defaults: UserDefaults
    ) -> [MailDomain.ID: String] {
        var overrides: [MailDomain.ID: String] = [:]
        for domain in domains {
            if let override = DomainPreferences.monogramOverride(accountID: accountID, domainID: domain.id, in: defaults) {
                overrides[domain.id] = override
            }
        }
        return overrides
    }

    /// Each domain's badge letters, clashes and overrides resolved across ALL
    /// the account's domains (hidden ones included, so hiding one never
    /// changes the letters another already shows).
    static func monograms(
        for domains: [MailDomain], accountID: String, in defaults: UserDefaults
    ) -> [MailDomain.ID: String] {
        DomainMonogram.assign(
            domains: domains,
            overrides: monogramOverrides(for: domains, accountID: accountID, in: defaults)
        )
    }
}

/// A domain's badge: the monogram on a wash of the owning ACCOUNT's tint
/// (handoff §2 — "Domain → badge… The tile is a wash of the account's tint").
/// One reusable piece other phases draw too (the sidebar's 18pt row, a domain
/// settings header's 22–24pt tile) rather than each hand-rolling the wash and
/// radius pairing.
///
/// Never the only cue: the caller always shows the domain name alongside it
/// (the design's own rule, §2 "Never colour alone") — this view draws just the
/// tile, and is `accessibilityHidden` for exactly that reason.
struct DomainBadge: View {
    let monogram: String
    let tint: MailTheme.AccountTint
    var size: Size = .row
    /// Set when the badge sits on a SELECTED `List` row (a conversation row,
    /// the sidebar). The letters then draw `.primary`, which flips to white
    /// with the focused accent selection; the fixed `ink` they draw everywhere
    /// else is about 3:1 on that fill. Unselected rows keep the design's `ink`.
    var isSelected = false

    enum Size {
        /// 16pt — a conversation row.
        case row
        /// 18pt — the sidebar.
        case sidebar
        /// 22–24pt — a header (settings, the reading pane's To/From chip).
        case header

        var diameter: CGFloat {
            switch self {
            case .row: 16
            case .sidebar: 18
            case .header: 24
            }
        }

        var radius: CGFloat {
            switch self {
            case .row: MailTheme.Radius.badgeSmall
            case .sidebar: MailTheme.Radius.badgeMedium
            case .header: MailTheme.Radius.badgeLarge
            }
        }
    }

    var body: some View {
        Text(monogram)
            .textStyle(MailTheme.Typography.badge)
            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(MailTheme.Color.ink))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(minWidth: size.diameter, minHeight: size.diameter)
            .padding(.horizontal, MailTheme.Spacing.xxs)
            .background(tint.solid.opacity(MailTheme.Wash.badgeFill), in: RoundedRectangle(cornerRadius: size.radius))
            .overlay {
                RoundedRectangle(cornerRadius: size.radius)
                    .strokeBorder(tint.solid.opacity(MailTheme.Wash.badgeBorder))
            }
            // Decorative: the domain NAME is what a caller shows beside it
            // (never the badge alone), so VoiceOver reads that, not "AC".
            .accessibilityHidden(true)
    }
}
