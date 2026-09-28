import Foundation
import HeraldKit

/// Where the Settings window is: a root page, or one page of one domain.
///
/// Lives on ``AppEnvironment`` (``AppEnvironment/settingsRoute``) rather than in
/// the Settings view, because SwiftUI's `openSettings` takes no argument: a deep
/// link ("Settings…" → Account, "Domain Settings…" → a domain's Overview) sets
/// the route FIRST and then opens the window — see
/// ``AppEnvironment/showSettings(_:accountID:open:)``.
///
/// A route is only a request. What the window actually draws is
/// ``resolved(hasAccount:visibleDomainIDs:)``, so a route naming a domain the
/// account no longer shows (hidden, lost access, or a different account now in
/// front) never leaves the detail pane on a page with nothing behind it — and
/// the stored route is left alone, so a domain whose mailboxes simply have not
/// loaded yet still opens once they do.
nonisolated enum SettingsRoute: Hashable, Sendable {
    case general
    case notifications
    case privacy
    case account
    case signatures
    case domain(MailDomain.ID, DomainSettingsPage)

    /// The domain this route drills into, if any — i.e. whether the sidebar is
    /// at its domain level.
    var domainID: MailDomain.ID? {
        if case .domain(let id, _) = self { return id }
        return nil
    }

    /// The page this route draws, once resolved.
    func resolved(hasAccount: Bool, visibleDomainIDs: Set<MailDomain.ID>) -> SettingsRoute {
        switch self {
        case .general, .notifications, .privacy:
            return self
        case .account, .signatures:
            return hasAccount ? self : .general
        case .domain(let id, _):
            guard hasAccount else { return .general }
            // Back to the account's own page rather than the root: the domain
            // belonged to this account, so that is the nearest page still there.
            return visibleDomainIDs.contains(id) ? self : .account
        }
    }

    /// The detail pane's serif title.
    var title: String {
        switch self {
        case .general: "General"
        case .notifications: "Notifications"
        case .privacy: "Privacy"
        case .account: "Account"
        case .signatures: "Signatures"
        case .domain(_, let page): page.title
        }
    }

    /// The sidebar glyph (handoff §5 icon map).
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .notifications: "bell"
        case .privacy: "hand.raised"
        case .account: "person.crop.circle"
        case .signatures: "signature"
        case .domain(_, let page): page.symbol
        }
    }

    /// The suffix of this route's sidebar item identifier
    /// (`AccessibilityID.Settings.itemPrefix`). A domain PAGE is keyed by page
    /// only — the domain level shows one domain at a time.
    var accessibilityKey: String {
        switch self {
        case .general: "general"
        case .notifications: "notifications"
        case .privacy: "privacy"
        case .account: "account"
        case .signatures: "signatures"
        case .domain(_, let page): "page.\(page.rawValue)"
        }
    }

    /// The caption over the title: "Settings › Herald" for the app-wide pages,
    /// "Settings › {account}" for the account's, and "Settings › {account} ›
    /// {domain}" inside a domain. Pure so the wording is assertable without a
    /// rendered window.
    func breadcrumb(accountLabel: String?, domainName: String?) -> String {
        var parts = ["Settings"]
        switch self {
        case .general, .notifications, .privacy:
            parts.append("Herald")
        case .account, .signatures:
            if let accountLabel { parts.append(accountLabel) }
        case .domain:
            if let accountLabel { parts.append(accountLabel) }
            if let domainName { parts.append(domainName) }
        }
        return parts.joined(separator: " › ")
    }

    /// The root level's groups, in sidebar order. Domains follow as their own
    /// section, built from the account's visible domains.
    static let rootGroups: [(title: String, routes: [SettingsRoute])] = [
        ("Herald", [.general, .notifications, .privacy]),
        ("Account", [.account, .signatures]),
    ]
}

/// One page of a domain's settings. Workflows is not here: it is a disabled
/// "LATER" row with nothing to select, so it has no route at all.
nonisolated enum DomainSettingsPage: String, Hashable, Sendable, CaseIterable {
    case overview
    case mailboxes
    case signatures
    /// "Remove domain" — pinned to the bottom of the domain level. Hide, not
    /// delete: nothing on it is destructive (handoff §3.2).
    case remove

    var title: String {
        switch self {
        case .overview: "Overview"
        case .mailboxes: "Mailboxes"
        case .signatures: "Signatures"
        case .remove: "Remove domain"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "info.circle"
        case .mailboxes: "at"
        case .signatures: "signature"
        case .remove: "eye.slash"
        }
    }
}

/// A domain as the Settings sidebar lists it: the derived domain plus the badge
/// letters it draws.
nonisolated struct SettingsDomainItem: Hashable, Sendable, Identifiable {
    let domain: MailDomain
    let monogram: String

    var id: MailDomain.ID { domain.id }

    /// The account's domains that Settings lists — every derived domain except
    /// the hidden ones (R9's Hidden Domains list is where those come back) and
    /// those with no mailbox left enabled at the server (``Mailbox/isEnabled``;
    /// only the server can switch them back on). Pass EVERY cached mailbox.
    ///
    /// Monograms are assigned across ALL of the account's domains, hidden and
    /// server-disabled ones included, so neither changes the letters another
    /// domain already shows everywhere else. Main-actor because `MailDomain.domains`
    /// is (HeraldKit is default-MainActor).
    @MainActor static func visible(
        mailboxes: [Mailbox],
        accountID: String,
        defaults: UserDefaults
    ) -> [SettingsDomainItem] {
        let domains = MailDomain.domains(from: mailboxes)
        var overrides: [MailDomain.ID: String] = [:]
        for domain in domains {
            if let raw = DomainPreferences.monogramOverride(accountID: accountID, domainID: domain.id, in: defaults) {
                overrides[domain.id] = raw
            }
        }
        let monograms = DomainMonogram.assign(domains: domains, overrides: overrides)
        return MailDomain.domains(from: mailboxes.filter(\.isEnabled))
            .filter { !DomainPreferences.isHidden(accountID: accountID, domainID: $0.id, in: defaults) }
            .map { SettingsDomainItem(domain: $0, monogram: monograms[$0.id] ?? DomainMonogram.derive(from: $0.name)) }
    }
}
