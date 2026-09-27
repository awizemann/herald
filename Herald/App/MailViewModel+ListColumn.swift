import Foundation
import HeraldKit

/// The middle column's reads of view-model state (redesign R5): the live
/// inputs to the pure rules in ``ListColumn``. Derived on read — nothing here
/// is stored or observed on its own; each reads observed state (`location`,
/// `mailboxes`, `domains`, the counts) and so re-renders with it.
extension MailViewModel {
    /// The scope as the list header and the search field name it: "All
    /// domains", "acme.co", "sales@acme.co".
    var listScopeName: String {
        ListColumn.scopeName(scope, domains: domains, mailboxes: mailboxes)
    }

    /// The toolbar search field's placeholder.
    var searchPrompt: String {
        ListColumn.searchPrompt(scope, scopeName: listScopeName)
    }

    /// The header caption, "{scope} · {folder}".
    var listCaption: String {
        ListColumn.caption(scopeName: listScopeName, folder: folder)
    }

    /// The count a folder menu row shows (Inbox unread, Drafts total), or nil.
    func folderMenuCount(for folder: Folder) -> Int? {
        ListColumn.menuCount(for: folder, unreadByFolder: folderUnreadCounts, draftCount: draftCount)
    }

    /// What the list says when it has no rows.
    var listEmptyState: ListColumn.EmptyState {
        ListColumn.emptyState(
            folder: folder,
            scope: scope,
            scopeName: listScopeName,
            labelName: selectedLabel?.name,
            searching: !searchQuery.isEmpty,
            serverSearchPending: serverSearchState == .idle
        )
    }

    /// The drafts empty state's "Show All Drafts": back to All domains, still
    /// in Drafts. `selectAllDomains` keeps the folder (and closes a label,
    /// which Drafts ignores anyway).
    func showAllDrafts() {
        selectAllDomains()
    }

    /// Row attribution for the current scope, resolved once per list pass.
    /// Monogram overrides are read through the view-model's own injected
    /// defaults, like every other Herald-only preference.
    func rowAttributionIndex() -> ListColumn.AttributionIndex {
        let level = ListColumn.AttributionLevel(scope: scope)
        guard level != .none else { return .empty }
        var overrides: [MailDomain.ID: String] = [:]
        if level == .domainAndMailbox {
            for domain in domains {
                if let override = DomainPreferences.monogramOverride(
                    accountID: accountID, domainID: domain.id, in: defaults
                ) {
                    overrides[domain.id] = override
                }
            }
        }
        return ListColumn.AttributionIndex.make(
            level: level, mailboxes: mailboxes, domains: domains,
            monogramOverrides: overrides, accountID: accountID
        )
    }

    /// Every address the account's mailboxes own, lowercased — what marks a
    /// thread message as the user's own (its avatar takes the account tint).
    var ownAddressKeys: Set<String> {
        Set(ownAddresses.map { $0.lowercased() })
    }

    /// The ONE place the list column reads the account tint.
    ///
    /// Observed: ``accountTint`` reads the view-model's tint revision, which
    /// `AppEnvironment.setAccountTint` bumps, so a colour changed in Settings
    /// repaints the list at once.
    var listAccountTint: MailTheme.AccountTint? {
        accountTint
    }
}
