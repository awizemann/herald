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
    /// ``resolvedSettingsRoute`` resolves a route standing on this domain's
    /// page away the moment the write lands (a domain id no longer in
    /// ``settingsDomains(accountID:)``, hidden ones filtered out there,
    /// reads as "not there" and falls back to `.account`) — but the RAW
    /// ``AppEnvironment/settingsRoute`` is left alone by that resolution on
    /// purpose (restoring within the same session brings the same page back).
    /// That raw route staying on the hidden domain used to strand a later
    /// click: `SettingsView`'s selection setter compares against the raw
    /// route too (so clicking the row already highlighted — Account, once
    /// resolution moved the highlight there — was a no-op), so nothing ever
    /// rewrote it off the domain and a subsequent Restore reopened straight
    /// to the hidden domain's own page instead of staying on Account (audit
    /// F3 #4). Hiding now rewrites the raw route itself when it points INSIDE
    /// the domain being hidden — any of its pages, not just this one.
    func hideDomain(_ domainID: MailDomain.ID, accountID: Account.ID) async {
        guard let mail = graphs[accountID]?.mail else { return }
        if mail.scopeIsInside(domainID: domainID) {
            mail.pendingNavigationSource = .sidebar
            mail.selectScope(.allDomains)
        }
        if settingsRoute.domainID == domainID {
            settingsRoute = .account
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
    /// https, and otherwise the origin's scheme/host/port with no path, query,
    /// fragment or userinfo — whatever Herald itself may have appended to
    /// `origin` (it never does today, but this is the one place that would
    /// matter) is dropped rather than carried into a URL that leaves the app.
    ///
    /// Built by clearing the irrelevant components OFF `origin`'s own parse
    /// rather than re-assembling a fresh `URLComponents` from `.host` — an
    /// IPv6-literal origin's `.host` comes back withOUT the `[...]` brackets
    /// (`URLComponents.host` strips them), so reassigning it to a new
    /// components' `.host` produced a URL Foundation refused to render and
    /// the button silently did nothing. Reusing the original parse keeps its
    /// bracketed host representation intact.
    static func hqBaseAdminURL(for account: Account) -> URL? {
        guard account.origin.scheme?.lowercased() == "https" else { return nil }
        guard var components = URLComponents(url: account.origin, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty
        else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
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
