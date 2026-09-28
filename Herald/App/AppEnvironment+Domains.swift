import AppKit
import Foundation
import HeraldKit

/// Domain-level verbs that are not preferences pages: what the sidebar's domain
/// context menu does (R4), and what Settings › Remove domain reuses (R9).
extension AppEnvironment {
    /// "Hide from Herald": the domain leaves the sidebar, the counts, the Dock
    /// badge and notifications on this Mac. Nothing on the server changes.
    ///
    /// A window standing IN the domain (the domain itself or one of its
    /// mailboxes) moves out to All domains first — keeping its folder and label,
    /// like any scope change — so it is never left listing mail from a domain
    /// the user just asked not to see. Moved before the write so the list's
    /// reload already sees the domain hidden.
    ///
    /// Settings needs no matching move: a route standing on this domain's page
    /// resolves itself away the moment the write lands, since
    /// ``SettingsRoute/resolved(hasAccount:visibleDomainIDs:)`` already treats a
    /// domain id no longer in ``settingsDomains(accountID:)`` (hidden ones are
    /// filtered out there) as "not there" and falls back to `.account`.
    func hideDomain(_ domainID: MailDomain.ID, accountID: Account.ID) async {
        guard let mail = graphs[accountID]?.mail else { return }
        if mail.scopeIsInside(domainID: domainID) {
            mail.pendingNavigationSource = .sidebar
            mail.selectScope(.allDomains)
        }
        // Captured before the write, from the domains the account currently
        // derives (hidden ones included) — this is what the Hidden Domains
        // list falls back to once the domain's mailboxes are gone from the
        // cache (`HiddenDomainItem.hidden(mailboxes:accountID:defaults:)`).
        let name = mail.domains.first { $0.id == domainID }?.name
        await updateDomainPreferences(accountID: accountID) { defaults in
            DomainPreferences.setHidden(true, accountID: accountID, domainID: domainID, in: defaults, name: name)
        }
    }

    /// "Restore": the reverse of ``hideDomain(_:accountID:)``. The domain was
    /// never in scope while hidden (the sidebar and "All domains" both exclude
    /// it), so there is no scope to move back — restoring only clears the
    /// preference, and the one write path's reload does the rest (the sidebar,
    /// counts, badge and notifications all pick it back up).
    func restoreDomain(_ domainID: MailDomain.ID, accountID: Account.ID) async {
        await updateDomainPreferences(accountID: accountID) { defaults in
            DomainPreferences.setHidden(false, accountID: accountID, domainID: domainID, in: defaults)
        }
    }

    /// N5: "Open in HQBase Admin ↗" opens the account's origin ROOT — never a
    /// path Herald builds from anything user-controlled, and refused unless
    /// the origin is https. `Account.origin` is already refused as non-https
    /// at sign-in (OAuth discovery — see "Herald Error Handling and Security
    /// Rules"), so this is a last line, not the primary guard: a button that
    /// hands `NSWorkspace` a URL must never trust a stored value without
    /// checking it again itself.
    func openHQBaseAdmin(for account: Account) {
        guard let url = Self.hqBaseAdminURL(for: account) else { return }
        NSWorkspace.shared.open(url)
    }

    /// The pure half of ``openHQBaseAdmin(for:)``: `nil` for anything but
    /// https, and otherwise the origin's scheme/host/port with no path, query
    /// or fragment — whatever Herald itself may have appended to `origin` (it
    /// never does today, but this is the one place that would matter) is
    /// dropped rather than carried into a URL that leaves the app.
    static func hqBaseAdminURL(for account: Account) -> URL? {
        guard account.origin.scheme?.lowercased() == "https", let host = account.origin.host else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = account.origin.port
        return components.url
    }
}

extension MailViewModel {
    /// Whether the scope is the domain or one of its mailboxes.
    func scopeIsInside(domainID: MailDomain.ID) -> Bool {
        switch scope {
        case .allDomains:
            false
        case .domain(let id):
            id == domainID
        case .mailbox(let id):
            domains.first { $0.id == domainID }?.mailboxIDs.contains(id) ?? false
        }
    }
}
