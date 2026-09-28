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

    /// How many Mark All as Read requests are in flight at once. Unbounded, a
    /// busy domain fired its whole backlog at the server in one burst.
    nonisolated static let markAllConcurrency = 5
    /// Mark All as Read reloads the list and counts after this many requests
    /// complete, so a long run visibly progresses instead of jumping at the end.
    nonisolated static let markAllReloadInterval = 20

    /// One request a Mark All as Read makes.
    nonisolated enum MarkReadTarget: Sendable, Hashable {
        /// `POST /conversations/{id}/read` for a thread whose unread Inbox
        /// rows all sit in the domain. `representative` is the row's newest
        /// message, for a thread the cache holds no messages of.
        case conversation(threadID: String, representative: String)
        /// `POST /messages/{id}/read` for one message of a thread that is
        /// ALSO unread in another domain's Inbox.
        case message(String)
    }

    /// Which threads Mark All as Read may mark wholesale, and which it must
    /// mark message by message. Pure.
    ///
    /// The conversation route marks EVERY accessible message of the thread in
    /// the folder — the other domain's copy included (the server fans the
    /// write out over the thread; `MailStore.applyLocalAction(_:threadID:)`
    /// does the same locally). So a thread with unread Inbox rows in another
    /// domain too is split out for the per-message route, which touches only
    /// what the user asked for. A cached row's unread count is THREAD-wide
    /// (`MailStore.refreshConversationRows`), so in practice any thread with
    /// an Inbox row in another domain is split while anything in it is unread
    /// — and the domain's own row keeps reading unread until the other
    /// domain's copy is read too. Only a thread with no Inbox row elsewhere
    /// takes the one-request route.
    ///
    /// Only rows that COUNT in the Inbox are candidates (``UnreadConversationKey/counts(in:)``):
    /// a row a local archive just moved out keeps its inbox listing until the
    /// next pass, and must not be POSTed. Each thread appears once, however
    /// many of the domain's mailboxes list it.
    nonisolated static func markAllPlan(
        keys: [UnreadConversationKey], domainMailboxIDs: Set<String>
    ) -> (whole: [(threadID: String, representative: String)], split: [(threadID: String, fallback: [String])]) {
        var order: [String] = []
        var latestInDomain: [String: [String]] = [:]
        var elsewhere: Set<String> = []
        for key in keys where key.counts(in: .inbox) {
            if domainMailboxIDs.contains(key.mailboxKey) {
                if latestInDomain[key.threadID] == nil { order.append(key.threadID) }
                latestInDomain[key.threadID, default: []].append(key.latestMessageID)
            } else {
                elsewhere.insert(key.threadID)
            }
        }
        var whole: [(threadID: String, representative: String)] = []
        var split: [(threadID: String, fallback: [String])] = []
        for threadID in order {
            let latest = (latestInDomain[threadID] ?? []).filter { !$0.isEmpty }
            if elsewhere.contains(threadID) {
                split.append((threadID, latest))
            } else {
                whole.append((threadID, latest.first ?? ""))
            }
        }
        return (whole, split)
    }

    /// The sidebar's "Mark All as Read": starts the run on a task the
    /// view-model OWNS (``markAllTask``), so sign-out's `stop()` cancels it.
    ///
    /// Re-entry while a run is going is IGNORED, not cancel-and-restart: the
    /// running pass already covers everything unread (whatever arrived since is
    /// what the next click is for), and restarting would re-send every request
    /// still in flight.
    func beginMarkAllAsRead(inDomain domainID: MailDomain.ID) {
        guard markAllTask == nil else { return }
        markAllTask = Task { [weak self] in
            await self?.runMarkAllAsRead(inDomain: domainID)
            self?.markAllTask = nil
        }
    }

    /// ``beginMarkAllAsRead(inDomain:)``, then waits for the run (the one
    /// already going, if there is one).
    func markAllAsRead(inDomain domainID: MailDomain.ID) async {
        beginMarkAllAsRead(inDomain: domainID)
        await markAllTask?.value
    }

    /// "Mark All as Read" on a domain: every unread thread in the domain's
    /// Inbox — all of its mailboxes, whatever the current scope, folder or
    /// label — and nothing of another domain's (``markAllPlan(keys:domainMailboxIDs:)``).
    ///
    /// Every request goes through the same optimistic service a row's Mark as
    /// Read uses (cache first, revert exactly on failure), at most
    /// ``markAllConcurrency`` at a time. The list and counts reload every
    /// ``markAllReloadInterval`` completions and at the end; the first failure
    /// is what the alert shows.
    private func runMarkAllAsRead(inDomain domainID: MailDomain.ID) async {
        guard let domain = domains.first(where: { $0.id == domainID }) else { return }
        let domainIDs = Set(domain.mailboxIDs)
        let targets: [MarkReadTarget]
        let threadCount: Int
        do {
            let plan = Self.markAllPlan(
                keys: try await store.unreadConversationKeys(accountID: accountID), domainMailboxIDs: domainIDs
            )
            var list = plan.whole.map { MarkReadTarget.conversation(threadID: $0.threadID, representative: $0.representative) }
            for thread in plan.split {
                list += try await splitTargets(thread, domainMailboxIDs: domainIDs)
            }
            targets = list
            threadCount = plan.whole.count + plan.split.count
        } catch {
            actionError = error.localizedDescription
            return
        }
        guard !targets.isEmpty, !Task.isCancelled else { return }
        record(.messageActionPerformed(
            action: Self.usageAction(for: ConversationAction.read), scope: .conversation, count: UsageBucket(count: threadCount)
        ))
        let actions = self.actions
        let accountID = self.accountID
        let failure: (any Error)? = await withTaskGroup(of: (any Error)?.self) { group in
            var next = 0
            func enqueue() {
                let target = targets[next]
                next += 1
                group.addTask {
                    do {
                        switch target {
                        case .conversation(let threadID, let representative):
                            try await actions.perform(
                                .read, onConversation: threadID, in: .inbox, accountID: accountID,
                                representativeMessageID: representative.isEmpty ? nil : representative
                            )
                        case .message(let id):
                            try await actions.perform(.read, on: id, accountID: accountID)
                        }
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            // A sliding window: one request starts as each one finishes.
            while next < min(Self.markAllConcurrency, targets.count) { enqueue() }
            var first: (any Error)?
            var completed = 0
            while let error = await group.next() {
                if first == nil { first = error }
                completed += 1
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                if next < targets.count { enqueue() }
                if completed % Self.markAllReloadInterval == 0, completed < targets.count {
                    await reloadConversations()
                }
            }
            return first
        }
        // Cancelled by `stop()`: the account is going away, and nothing here
        // is worth telling it.
        guard !Task.isCancelled else { return }
        if let failure {
            actionError = failure.localizedDescription
            record(.actionFailed(action: Self.usageAction(for: ConversationAction.read), kind: UsageMailErrorKind(anyError: failure)))
        }
        await reloadConversations()
    }

    /// The per-message requests for a thread split out by ``markAllPlan(keys:domainMailboxIDs:)``:
    /// its unread Inbox messages in the domain's mailboxes. A thread whose
    /// messages the cache does not hold falls back to its in-domain rows'
    /// newest messages — the most the cache can name.
    private func splitTargets(
        _ thread: (threadID: String, fallback: [String]), domainMailboxIDs: Set<String>
    ) async throws -> [MarkReadTarget] {
        let messages = try await store.messages(accountID: accountID, threadID: thread.threadID)
        let ids = messages.isEmpty
            ? thread.fallback
            : messages
                .filter { $0.isUnread && $0.folder == .inbox && domainMailboxIDs.contains($0.mailboxID ?? "") }
                .map(\.id)
        return ids.map(MarkReadTarget.message)
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
