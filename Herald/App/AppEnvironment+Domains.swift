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
    func hideDomain(_ domainID: MailDomain.ID, accountID: Account.ID) async {
        guard let mail = graphs[accountID]?.mail else { return }
        if mail.scopeIsInside(domainID: domainID) {
            mail.pendingNavigationSource = .sidebar
            mail.selectScope(.allDomains)
        }
        await updateDomainPreferences(accountID: accountID) { defaults in
            DomainPreferences.setHidden(true, accountID: accountID, domainID: domainID, in: defaults)
        }
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
