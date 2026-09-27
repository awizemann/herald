import AppKit
import Foundation
import HeraldKit

// The drill-down sidebar's logic (redesign R4): which level it shows, which row
// it highlights, what a row does, and the domain-level verbs of its context
// menu. Kept off the view so every rule is assertable without a rendered List —
// the view only maps these onto rows.

extension MailViewModel {
    /// Which of the sidebar's three levels is showing. DERIVED from the scope,
    /// never stored: All domains → Domains, a domain → its Mailboxes, a mailbox →
    /// its Folders. Persisting the scope (``NavigationPersistence``) therefore
    /// restores the level too, and nothing can leave the two disagreeing.
    nonisolated enum SidebarLevel: Hashable, Sendable {
        case domains
        case mailboxes(MailDomain.ID)
        /// The owning domain is `nil` only while the mailbox list has not
        /// loaded (a cold cache restoring a mailbox scope): the level still
        /// shows, and its back link goes to Domains.
        case folders(domain: MailDomain.ID?, mailbox: Mailbox.ID)

        /// The level a scope draws, given the account's domains.
        static func level(for scope: Scope, domains: [MailDomain]) -> SidebarLevel {
            switch scope {
            case .allDomains:
                return .domains
            case .domain(let id):
                return .mailboxes(id)
            case .mailbox(let id):
                return .folders(domain: domains.first { $0.mailboxIDs.contains(id) }?.id, mailbox: id)
            }
        }

        /// 1, 2 or 3 — for the view's animation and focus keys.
        var depth: Int {
            switch self {
            case .domains: 1
            case .mailboxes: 2
            case .folders: 3
            }
        }
    }

    /// One selectable sidebar row, across all three levels.
    nonisolated enum SidebarRow: Hashable, Sendable {
        case allDomains
        case domain(MailDomain.ID)
        case label(String)
        case allMailboxes
        case mailbox(Mailbox.ID)
        case folder(Folder)

        /// Rows that open the next level rather than showing a listing of
        /// their own. Arrowing onto one only highlights it (see
        /// ``activate(_:)``'s caller); a click, Return or → drills.
        var drillsIn: Bool {
            switch self {
            case .domain, .mailbox: true
            case .allDomains, .label, .allMailboxes, .folder: false
            }
        }
    }

    var sidebarLevel: SidebarLevel { SidebarLevel.level(for: scope, domains: domains) }

    /// The row the source list highlights for where the window is.
    ///
    /// - Level 1: the open label's row, else "All domains" (handoff: the label
    ///   row is highlighted only at this level). Behind Drafts an open label
    ///   narrows nothing, so All domains is what is showing.
    /// - Level 2: "All mailboxes" — even with a label open (the mock leaves the
    ///   level blank then; a List whose selection the click did not change
    ///   keeps drawing the clicked row, so blank is not reliably drawable).
    /// - Level 3: the folder — the level-3 list and the header folder menu
    ///   write the same value.
    var sidebarSelection: SidebarRow {
        switch sidebarLevel {
        case .domains:
            if let labelID = selectedLabelID, !isShowingDrafts { return .label(labelID) }
            return .allDomains
        case .mailboxes:
            return .allMailboxes
        case .folders:
            return .folder(folder)
        }
    }

    /// What picking a row does. Every row lands on an existing intent, so the
    /// redesign's rules hold here too: the folder survives every scope change,
    /// an open label survives drilling in, and only "All domains" (or the chip,
    /// or re-clicking the label — the view's job) closes it.
    func activate(_ row: SidebarRow) {
        pendingNavigationSource = .sidebar
        switch row {
        case .allDomains:
            selectAllDomains()
        case .domain(let id):
            selectScope(.domain(id))
        case .label(let id):
            // OPENS, never toggles: this is reached from a selection change, and
            // arrowing back onto the open label's row must not close it. From
            // Drafts `openLabel` lands on the Inbox with the label open.
            if selectedLabelID != id || isShowingDrafts {
                openLabel(id)
            } else {
                pendingNavigationSource = nil
            }
        case .allMailboxes:
            if case .mailboxes(let domainID) = sidebarLevel {
                selectScope(.domain(domainID))
            } else {
                pendingNavigationSource = nil
            }
        case .mailbox(let id):
            selectScope(.mailbox(id))
        case .folder(let folder):
            selectFolder(folder)
        }
    }

    /// "‹ Domains" / "‹ {domain}", and ← in the sidebar: one level up.
    ///
    /// The scope widens and NOTHING ELSE moves — the folder is kept (handoff
    /// "Scope and folder are independent") and so is an open label. The mock's
    /// back link sets only the domain/mailbox; the README's "clicking All
    /// domains clears it" is about the All domains ROW (`selectAllDomains`),
    /// which going back is not.
    func sidebarBack() {
        let target: Scope
        switch sidebarLevel {
        case .domains:
            return
        case .mailboxes:
            target = .allDomains
        case .folders(let domainID, _):
            target = domainID.map(Scope.domain) ?? .allDomains
        }
        pendingNavigationSource = .sidebar
        selectScope(target)
    }

    // MARK: Context menu

    /// "Mark All as Read" on a domain: every unread thread in the domain's
    /// Inbox — all of its mailboxes, whatever the current scope, folder or label.
    ///
    /// Each thread goes through the same optimistic conversation action a row's
    /// Mark as Read uses (cache first, revert exactly on failure), in parallel —
    /// the requests are independent, and one at a time a busy domain would take
    /// a round trip per thread before the counts moved. The list and counts
    /// reload once at the end; the first failure is what the alert shows.
    func markAllAsRead(inDomain domainID: MailDomain.ID) async {
        guard let domain = domains.first(where: { $0.id == domainID }) else { return }
        let threads: [ConversationSummary]
        do {
            threads = try await Self.unreadInboxThreads(
                store: store, accountID: accountID, mailboxIDs: Set(domain.mailboxIDs)
            )
        } catch {
            actionError = error.localizedDescription
            return
        }
        guard !threads.isEmpty else { return }
        record(.messageActionPerformed(
            action: Self.usageAction(for: ConversationAction.read), scope: .conversation, count: UsageBucket(count: threads.count)
        ))
        let actions = self.actions
        let accountID = self.accountID
        let failure: (any Error)? = await withTaskGroup(of: (any Error)?.self) { group in
            for thread in threads {
                let representative = thread.latest.id
                group.addTask {
                    do {
                        try await actions.perform(
                            .read, onConversation: thread.id, in: .inbox,
                            accountID: accountID, representativeMessageID: representative
                        )
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            var first: (any Error)?
            for await error in group where first == nil {
                first = error
            }
            return first
        }
        if let failure {
            actionError = failure.localizedDescription
            record(.actionFailed(action: Self.usageAction(for: ConversationAction.read), kind: UsageMailErrorKind(anyError: failure)))
        }
        await reloadConversations()
    }

    /// Every unread Inbox thread in a set of mailboxes, paged out of the cache
    /// (a domain can hold more than one listing page of them).
    nonisolated static func unreadInboxThreads(
        store: MailStore, accountID: String, mailboxIDs: Set<String>
    ) async throws -> [ConversationSummary] {
        let page = 500
        var offset = 0
        var unread: [ConversationSummary] = []
        while true {
            let rows = try await store.conversations(
                accountID: accountID, mailboxIDs: mailboxIDs, folder: .inbox, limit: page, offset: offset
            )
            unread += rows.filter(\.isUnread)
            guard rows.count == page else { return unread }
            offset += page
        }
    }
}

// MARK: - Presentation

/// Pure helpers the sidebar draws from.
nonisolated enum SidebarPresentation {
    /// Level 1 turns its filter glyph into a field once there are MORE than
    /// this many domains (handoff §3.1).
    static let domainFilterThreshold = 8

    static func showsDomainFilter(domainCount: Int) -> Bool {
        domainCount > domainFilterThreshold
    }

    /// The domains level 1 lists: every domain the user has not hidden. A
    /// domain taken out of "All domains" still has its own row — that toggle
    /// narrows the combined listing, it does not remove the domain.
    static func visibleDomains(
        _ domains: [MailDomain], accountID: String, preferences: UserDefaults
    ) -> [MailDomain] {
        domains.filter { !DomainPreferences.isHidden(accountID: accountID, domainID: $0.id, in: preferences) }
    }

    /// Case-insensitive "contains" on a domain's name. An empty (or blank)
    /// query keeps everything.
    static func filter<Item>(_ items: [Item], query: String, name: (Item) -> String) -> [Item] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return items }
        return items.filter { name($0).localizedCaseInsensitiveContains(needle) }
    }

    /// `sales@acme.co` → (`sales@`, `acme.co`): the mailbox row's bold local
    /// part and its ink3 domain. An address with no `@` is all local part.
    static func addressParts(_ address: String) -> (local: String, domain: String) {
        guard let at = address.lastIndex(of: "@") else { return (address, "") }
        return (String(address[...at]), String(address[address.index(after: at)...]))
    }

    /// The account card's caption before the sync status: "5 domains".
    static func domainCountCaption(_ count: Int) -> String {
        count == 1 ? "1 domain" : "\(count) domains"
    }

    /// A row's VoiceOver label: its name, then its unread count when there is
    /// one ("acme.co, 14 unread").
    static func accessibilityLabel(_ name: String, unread: Int) -> String {
        unread > 0 ? "\(name), \(unread) unread" : name
    }

    /// A sidebar item's height at a density (handoff §1: 30 / 26).
    static func itemHeight(for density: ListDensity) -> CGFloat {
        switch density {
        case .comfortable: 30
        case .compact: 26
        }
    }

    /// The popover's "Settings…" shortcut hint, drawn (not bound — the app
    /// menu owns ⌘,).
    static let settingsShortcut = "⌘,"

    /// Whether a selection change came from the pointer. A drill row picked
    /// by a click drills; picked by the arrow keys it is only highlighted, or
    /// arrowing down the domain list would jump into the first domain. A
    /// right-click is not a pick (it opens the context menu).
    @MainActor static func isPointerEvent(_ event: NSEvent?) -> Bool {
        guard let type = event?.type else { return false }
        return type == .leftMouseDown || type == .leftMouseUp || type == .leftMouseDragged
    }
}
