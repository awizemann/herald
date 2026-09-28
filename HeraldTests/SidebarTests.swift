import Foundation
import HeraldKit
import Testing
@testable import Herald

/// Redesign R4 — the drill-down sidebar's logic: level ↔ scope, what each row
/// and the back link do, which domains level 1 lists, the filter threshold,
/// and the domain context menu's Mark All as Read and Hide.
///
/// Uses ``ScopeHarness``'s fixture: acme.co (`mbSales`, `mbTeam`) and north.io
/// (`mbOps`); one unread inbox thread per mailbox, an archived `t_sales_arch`,
/// and `lbl_client` on `t_sales`, `t_ops` and `t_sales_arch`.
@MainActor
@Suite(.scratchDefaults)
struct SidebarTests {
    private typealias Level = MailViewModel.SidebarLevel
    private typealias Row = MailViewModel.SidebarRow

    // MARK: - Level ↔ scope

    /// Fails if the level stops following the scope (so a restored scope would
    /// land on the wrong level), or a mailbox level loses its owning domain.
    @Test("The level is derived from the scope")
    func levelFollowsScope() {
        let acme = MailDomain(id: "d1", name: "acme.co", mailboxIDs: ["a", "b"])
        let domains = [acme, MailDomain(id: "d2", name: "north.io", mailboxIDs: ["c"])]
        #expect(Level.level(for: .allDomains, domains: domains) == .domains)
        #expect(Level.level(for: .domain("d1"), domains: domains) == .mailboxes("d1"))
        #expect(Level.level(for: .mailbox("b"), domains: domains) == .folders(domain: "d1", mailbox: "b"))
        #expect(Level.level(for: .mailbox("c"), domains: domains) == .folders(domain: "d2", mailbox: "c"))
        // A cold cache: the mailbox scope still draws level 3, with no domain yet.
        #expect(Level.level(for: .mailbox("b"), domains: []) == .folders(domain: nil, mailbox: "b"))
    }

    /// Fails if the persisted scope does not bring the sidebar back to the
    /// level it was on (the level is not stored anywhere else).
    @Test("A persisted mailbox scope relaunches on level 3")
    func relaunchRestoresTheLevel() async throws {
        let defaults = ScratchDefaults.make()
        let first = try await ScopeHarness.make(persists: true, defaults: defaults)
        try await first.seed()
        await first.model.start()
        first.model.activate(.domain(ScopeHarness.acme))
        first.model.activate(.mailbox("mbTeam"))
        await first.settle()
        first.model.stop()

        // A fresh cache with the same mailboxes (the harness store is per
        // instance); only the defaults carry over, as across a relaunch.
        let second = try await ScopeHarness.make(persists: true, defaults: defaults)
        try await second.seed()
        await second.model.start()
        #expect(second.model.sidebarLevel == .folders(domain: ScopeHarness.acme, mailbox: "mbTeam"))
    }

    // MARK: - Rows

    /// Drilling in keeps the folder AND the open label (handoff: "an open label
    /// stays open while drilling in"); level 3's folder rows write the same
    /// folder value. Fails if any drill resets an axis it does not own.
    @Test("Drilling in keeps folder and label; folder rows set the folder")
    func drillingKeepsFolderAndLabel() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()
        let model = harness.model

        model.activate(.label("lbl_client"))
        #expect(model.sidebarSelection == .label("lbl_client"), "level 1 highlights the open label")
        model.activate(.domain(ScopeHarness.acme))
        #expect(model.scope == .domain(ScopeHarness.acme))
        #expect(model.selectedLabelID == "lbl_client")
        #expect(model.sidebarSelection == .allMailboxes, "deeper, the scope row is highlighted, not the label")

        model.activate(.mailbox("mbSales"))
        #expect(model.sidebarLevel == .folders(domain: ScopeHarness.acme, mailbox: "mbSales"))
        model.activate(.folder(.conversation(.archived)))
        await harness.settle()
        #expect(model.folder == .conversation(.archived))
        #expect(model.selectedLabelID == "lbl_client", "a level-3 folder keeps the label (mock: pick sets folder only)")
        #expect(model.sidebarSelection == .folder(.conversation(.archived)))
        #expect(harness.listed == ["t_sales_arch"], "mbSales ∩ Archived ∩ Client")
    }

    /// Back goes up one level and moves ONLY the scope: the folder and the
    /// label stay (the mock's back link sets the domain/mailbox only). Fails
    /// on a back that behaves like the All domains row and closes the label.
    @Test("Back widens the scope one level and keeps folder and label")
    func backKeepsFolderAndLabel() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()
        let model = harness.model
        model.selectFolder(.conversation(.sent))
        model.activate(.label("lbl_client"))
        model.activate(.domain(ScopeHarness.acme))
        model.activate(.mailbox("mbTeam"))

        model.sidebarBack()
        #expect(model.scope == .domain(ScopeHarness.acme), "level 3 → the mailbox's domain")
        model.sidebarBack()
        #expect(model.scope == .allDomains)
        #expect(model.folder == .conversation(.sent))
        #expect(model.selectedLabelID == "lbl_client")
        model.sidebarBack()
        #expect(model.scope == .allDomains, "no level above Domains")
    }

    /// The All domains ROW, unlike back, closes the label.
    @Test("All domains closes the label; re-activating the open label keeps it")
    func allDomainsRowClearsTheLabel() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()
        let model = harness.model
        model.activate(.label("lbl_client"))
        // Arrowing back onto the open label's row re-sets the selection: that
        // must not toggle it closed (the old `openLabel` toggle would).
        model.activate(.label("lbl_client"))
        #expect(model.selectedLabelID == "lbl_client")
        model.activate(.allDomains)
        #expect(model.selectedLabelID == nil)
        #expect(model.sidebarSelection == .allDomains)
    }

    /// Only domain and mailbox rows drill — they are the rows the arrow keys
    /// may highlight without opening.
    @Test func onlyDomainAndMailboxRowsDrill() {
        #expect(Row.domain("d").drillsIn)
        #expect(Row.mailbox("m").drillsIn)
        #expect(!Row.allDomains.drillsIn)
        #expect(!Row.allMailboxes.drillsIn)
        #expect(!Row.label("l").drillsIn)
        #expect(!Row.folder(.drafts).drillsIn)
    }

    // MARK: - Presentation

    /// Level 1 lists every domain except hidden ones; a domain only taken out
    /// of "All domains" keeps its row. Fails if the list reads the wrong
    /// preference (or none).
    @Test("Level 1 lists visible domains only")
    func visibleDomains() {
        let defaults = ScratchDefaults.make()
        let domains = [
            MailDomain(id: "d1", name: "acme.co", mailboxIDs: ["a"]),
            MailDomain(id: "d2", name: "north.io", mailboxIDs: ["b"]),
            MailDomain(id: "d3", name: "quiet.io", mailboxIDs: ["c"]),
        ]
        DomainPreferences.setHidden(true, accountID: "acct", domainID: "d2", in: defaults)
        DomainPreferences.setIncludeInAll(false, accountID: "acct", domainID: "d3", in: defaults)
        let visible = SidebarPresentation.visibleDomains(domains, accountID: "acct", preferences: defaults)
        #expect(visible.map(\.id) == ["d1", "d3"])
        #expect(SidebarPresentation.visibleDomains(domains, accountID: "other", preferences: defaults).count == 3)
    }

    /// The glyph becomes a field only PAST 8 domains; filtering is a
    /// case-insensitive contains, and a blank query keeps everything.
    @Test("Filter threshold and matching")
    func filterThresholdAndMatching() {
        #expect(!SidebarPresentation.showsDomainFilter(domainCount: 8))
        #expect(SidebarPresentation.showsDomainFilter(domainCount: 9))
        let names = ["acme.co", "Northwind.io", "fieldnotes.press"]
        #expect(SidebarPresentation.filter(names, query: "NORTH", name: { $0 }) == ["Northwind.io"])
        #expect(SidebarPresentation.filter(names, query: "  ", name: { $0 }) == names)
        #expect(SidebarPresentation.filter(names, query: "zzz", name: { $0 }).isEmpty)
    }

    @Test("Card caption, address parts, row labels and item heights")
    func presentationStrings() {
        #expect(SidebarPresentation.domainCountCaption(1) == "1 domain")
        #expect(SidebarPresentation.domainCountCaption(5) == "5 domains")
        #expect(SidebarPresentation.addressParts("sales@acme.co") == ("sales@", "acme.co"))
        #expect(SidebarPresentation.addressParts("nobody") == ("nobody", ""))
        #expect(SidebarPresentation.accessibilityLabel("acme.co", unread: 14) == "acme.co, 14 unread")
        #expect(SidebarPresentation.accessibilityLabel("acme.co", unread: 0) == "acme.co")
        #expect(SidebarAccountCard.accessibilityLabel(account: "Studio", unread: 25) == "Account: Studio, 25 unread")
        #expect(SidebarPresentation.itemHeight(for: .comfortable) == 30)
        #expect(SidebarPresentation.itemHeight(for: .compact) == 26)
        #expect(SidebarPresentation.mailboxFilterPrompt(count: 1) == "Filter 1 mailbox")
        #expect(SidebarPresentation.mailboxFilterPrompt(count: 7) == "Filter 7 mailboxes")
        #expect(SidebarPresentation.mailboxFilterPrompt(count: 0) == "Filter 0 mailboxes")
    }

    /// V2 audit: `defaultMinListRowHeight` alone left Compact sidebar rows at
    /// the medium size's 30pt. Compact must ask the system for `.small` rows
    /// (measured 24pt) and floor the content so the drawn row is 26; the
    /// floors differ by density, so a single shared value fails here.
    @Test("Compact sidebar rows use the small row size, padded to 26")
    func sidebarRowSizing() {
        #expect(SidebarPresentation.rowSize(for: .comfortable) == .medium)
        #expect(SidebarPresentation.rowSize(for: .compact) == .small)
        #expect(SidebarPresentation.itemContentMinHeight(for: .comfortable) == 18)
        #expect(SidebarPresentation.itemContentMinHeight(for: .compact) == 20)
    }

    /// V2 audit (5a-8): the 290pt account popover centred on a 232pt card
    /// hung past the window's leading edge. Anchored at half its width it
    /// starts on the card's leading edge; it never anchors left of centre.
    @Test("The account popover attaches so it starts at the card's leading edge")
    func accountPopoverAnchor() {
        #expect(abs(SidebarPresentation.accountPopoverAnchorX(cardWidth: 232, popoverWidth: 290) - 145.0 / 232.0) < 1e-9)
        // A card wider than the popover: centred is already inside it.
        #expect(SidebarPresentation.accountPopoverAnchorX(cardWidth: 400, popoverWidth: 290) == 0.5)
        // A very narrow card never anchors past its trailing edge.
        #expect(SidebarPresentation.accountPopoverAnchorX(cardWidth: 100, popoverWidth: 290) == 1)
        // Not measured yet.
        #expect(SidebarPresentation.accountPopoverAnchorX(cardWidth: 0, popoverWidth: 290) == 0.5)
    }

    /// The account card's number is the All domains Inbox unread — hidden
    /// domains excluded. Fails if the card sums every domain.
    @Test("The card's unread leaves hidden domains out")
    func cardUnreadExcludesHidden() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()
        #expect(harness.model.allDomainsInboxUnread == 3)
        DomainPreferences.setHidden(true, accountID: ScopeHarness.account, domainID: ScopeHarness.north, in: harness.defaults)
        await harness.model.domainPreferencesDidChange()
        #expect(harness.model.allDomainsInboxUnread == 2)
    }

    /// The observed-tint overload draws the tint it is HANDED (read through
    /// `AppEnvironment.accountTintName(for:)`), never the stored override —
    /// and still reads the monogram override from the defaults it is given.
    @Test("The observed resolver takes its tint from the caller")
    func observedResolverUsesTheGivenTint() {
        let defaults = ScratchDefaults.make()
        let mailboxes = [ScopeHarness.mailbox("mbSales", "sales@acme.co", domain: "dom_acme")]
        defaults.set("rose", forKey: AccountTintAssignment.storageKey(accountID: "acct"))
        DomainPreferences.setMonogramOverride("ZZ", accountID: "acct", domainID: "dom_acme", in: defaults)
        let info = DomainBadgeResolver.resolve(
            mailboxID: "mbSales", mailboxes: mailboxes, accountID: "acct", tintName: "sage", in: defaults
        )
        #expect(info?.tintName == "sage")
        #expect(info?.monogram == "ZZ")
        #expect(info?.domainName == "acme.co")
        #expect(DomainBadgeResolver.resolve(
            mailboxID: "nope", mailboxes: mailboxes, accountID: "acct", tintName: "sage", in: defaults
        ) == nil)
    }

    // MARK: - Mark All as Read

    /// Marks exactly the domain's unread INBOX threads — every mailbox of the
    /// domain, whatever the window's scope/folder — through the conversation
    /// route with the Inbox folder, each thread ONCE. Around the fixture:
    /// - `t_read`: already read — not sent;
    /// - `t_twice`: unread in BOTH acme mailboxes — one request, not two;
    /// - `t_gone`: unread in mbTeam but archived locally a moment ago (its
    ///   inbox row still listed) — not sent;
    /// - `t_cross`: unread in acme's mbSales AND north's mbOps — the
    ///   conversation route would mark north's copy too, so only acme's
    ///   MESSAGE goes, by the message route, and north keeps its unread.
    /// Fails on the old run (every listed row through the conversation route:
    /// `t_twice` twice, `t_gone` and `t_cross` wholesale), if it follows the
    /// current listing, or touches another domain.
    @Test("Mark All as Read covers the domain's unread Inbox only, once per thread")
    func markAllAsReadScope() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        let account = ScopeHarness.account
        func add(_ id: String, thread: String, in mailbox: String, read: Bool = false, minute: Int) async throws {
            let message = MailFixtures.message(
                id: id, threadID: thread, mailboxID: mailbox, read: read,
                date: MailFixtures.epoch.addingTimeInterval(TimeInterval(3_600 + minute * 60))
            )
            try await harness.store.upsertMessages([message], accountID: account)
            try await harness.store.upsertConversations(
                [MailFixtures.conversation(message, unread: read ? 0 : 1)], accountID: account, mailboxID: mailbox, folder: .inbox
            )
            // The message route answers with this summary, read.
            await harness.api.setDetail(MailFixtures.detail(message))
        }
        try await add("m_read", thread: "t_read", in: "mbTeam", read: true, minute: 1)
        try await add("m_twice_s", thread: "t_twice", in: "mbSales", minute: 2)
        try await add("m_twice_t", thread: "t_twice", in: "mbTeam", minute: 3)
        try await add("m_gone", thread: "t_gone", in: "mbTeam", minute: 4)
        try await add("m_cross_a", thread: "t_cross", in: "mbSales", minute: 5)
        try await add("m_cross_n", thread: "t_cross", in: "mbOps", minute: 6)
        _ = try await harness.store.applyLocalAction(.archive, messageID: "m_gone", accountID: account)
        await harness.model.start()
        #expect(harness.model.inboxUnreadByDomain[ScopeHarness.acme] == 4, "t_sales, t_team, t_twice, t_cross")
        // Standing somewhere else entirely.
        harness.model.selectScope(.domain(ScopeHarness.north))
        harness.model.selectFolder(.conversation(.sent))
        await harness.settle()

        await harness.model.markAllAsRead(inDomain: ScopeHarness.acme)

        let whole = await harness.api.conversationActionIDs("read")
        #expect(whole.sorted() == ["m_t_sales", "m_t_team", "m_twice_t"], "one request per thread, newest member")
        #expect(await harness.api.actionFolders("read", on: "m_t_sales") == [.inbox])
        #expect(await harness.api.messageActionIDs("read") == ["m_cross_a"], "only acme's copy of the shared thread")
        // A cached conversation row's unread is THREAD-wide (MailStore's
        // `refreshConversationRows`), so acme's row of t_cross still reads
        // unread while north's message is — the price of not marking north's.
        #expect(harness.model.inboxUnreadByDomain[ScopeHarness.acme] == 1, "only the shared t_cross remains")
        #expect(harness.model.inboxUnreadByDomain[ScopeHarness.north] == 2, "north keeps t_ops AND its copy of t_cross")
        #expect(harness.model.actionError == nil)
        #expect(harness.model.markAllTask == nil, "the finished run released its task")
    }

    /// Many threads: at most `markAllConcurrency` requests are ever in flight,
    /// the list reloads part-way (every `markAllReloadInterval` completions),
    /// and a second click while it runs starts nothing. Fails on the old
    /// unbounded group (all 30 parked at once), on a single reload at the end,
    /// or on a re-entry that re-sends the batch.
    @Test("Mark All as Read is bounded, reloads as it goes, and ignores re-entry", .timeLimit(.minutes(1)))
    func markAllAsReadIsBounded() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        let threads = (1...30).map { "t_bulk\($0)" }
        for (index, thread) in threads.enumerated() {
            let message = MailFixtures.message(
                id: "m_\(thread)", threadID: thread, mailboxID: "mbSales",
                date: MailFixtures.epoch.addingTimeInterval(TimeInterval(7_200 + index * 60))
            )
            try await harness.store.upsertMessages([message], accountID: ScopeHarness.account)
            try await harness.store.upsertConversations(
                [MailFixtures.conversation(message)], accountID: ScopeHarness.account, mailboxID: "mbSales", folder: .inbox
            )
        }
        await harness.model.start()
        let reloadsBefore = harness.model.conversationReloadCount
        await harness.api.closeActionGate()

        harness.model.beginMarkAllAsRead(inDomain: ScopeHarness.acme)
        await harness.api.waitForParkedActions(count: MailViewModel.markAllConcurrency)
        // Give an unbounded implementation every chance to over-issue.
        for _ in 0..<200 { await Task.yield() }
        #expect(await harness.api.parkedActionCount == MailViewModel.markAllConcurrency)
        harness.model.beginMarkAllAsRead(inDomain: ScopeHarness.acme)
        await harness.api.openActionGate()
        await harness.model.markAllTask?.value

        let sent = await harness.api.conversationActionIDs("read")
        #expect(sent.count == 32, "30 bulk threads + t_sales + t_team, each once — the second click added nothing")
        #expect(Set(sent).count == 32)
        #expect(await harness.api.maxActionsInFlight <= MailViewModel.markAllConcurrency)
        #expect(
            harness.model.conversationReloadCount - reloadsBefore == 2,
            "one reload at \(MailViewModel.markAllReloadInterval) completions, one at the end"
        )
        #expect(harness.model.inboxUnreadByDomain[ScopeHarness.acme] == nil)
    }

    /// Sign-out's `stop()` cancels a running Mark All as Read: nothing past the
    /// requests already in flight is sent. Fails when the run is an unowned
    /// `Task` in the view (it POSTs the rest for an account that is gone).
    @Test("stop() cancels a running Mark All as Read", .timeLimit(.minutes(1)))
    func markAllAsReadStopsWithTheAccount() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        for index in 1...20 {
            let message = MailFixtures.message(
                id: "m_s\(index)", threadID: "t_s\(index)", mailboxID: "mbTeam",
                date: MailFixtures.epoch.addingTimeInterval(TimeInterval(7_200 + index * 60))
            )
            try await harness.store.upsertMessages([message], accountID: ScopeHarness.account)
            try await harness.store.upsertConversations(
                [MailFixtures.conversation(message)], accountID: ScopeHarness.account, mailboxID: "mbTeam", folder: .inbox
            )
        }
        await harness.model.start()
        await harness.api.closeActionGate()
        harness.model.beginMarkAllAsRead(inDomain: ScopeHarness.acme)
        await harness.api.waitForParkedActions(count: MailViewModel.markAllConcurrency)
        let task = harness.model.markAllTask
        harness.model.stop()
        await harness.api.openActionGate()
        await task?.value
        #expect(await harness.api.conversationActionIDs("read").count == MailViewModel.markAllConcurrency)
    }

    /// A rejected request reverts (the service's optimistic rule) and says so.
    @Test("A rejected Mark All as Read reverts and reports")
    func markAllAsReadFailure() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()
        await harness.api.setActionError(.server(code: "boom", message: "nope"))
        await harness.model.markAllAsRead(inDomain: ScopeHarness.acme)
        #expect(harness.model.actionError != nil)
        #expect(harness.model.inboxUnreadByDomain[ScopeHarness.acme] == 2, "reverted")
    }

    // MARK: - Hide

    /// Hide writes `hidden` through the one preferences path, and a window
    /// standing in the domain (or one of its mailboxes) moves to All domains
    /// keeping its folder. Fails if the window is left listing a hidden
    /// domain, if the folder resets, or if the hide misses All domains.
    @Test("Hide moves out of the hidden domain, keeping the folder")
    func hideMovesOutKeepingFolder() async throws {
        let (environment, mail, id) = try await Self.environment()
        mail.selectFolder(.conversation(.sent))
        mail.selectScope(.mailbox("mb_acme"))

        await environment.hideDomain("dom_acme", accountID: id)

        #expect(DomainPreferences.isHidden(accountID: id, domainID: "dom_acme", in: environment.defaults))
        #expect(mail.scope == .allDomains)
        #expect(mail.folder == .conversation(.sent))
        #expect(mail.mailboxIDs(for: .allDomains) == ["mb_nw", MailViewModel.unassignedMailboxKey])
    }

    /// Hiding a domain the window is NOT in leaves the scope alone.
    @Test("Hide elsewhere keeps the scope")
    func hideElsewhereKeepsScope() async throws {
        let (environment, mail, id) = try await Self.environment()
        mail.selectScope(.domain("dom_nw"))
        await environment.hideDomain("dom_acme", accountID: id)
        #expect(mail.scope == .domain("dom_nw"))
        #expect(mail.scopeIsInside(domainID: "dom_nw"))
        #expect(!mail.scopeIsInside(domainID: "dom_acme"))
    }

    private static func environment() async throws -> (AppEnvironment, MailViewModel, Account.ID) {
        let account = Account(origin: URL(string: "https://a.example.com")!, clientID: "cid", scopes: [])
        let environment = AppEnvironment(
            auth: AuthCoordinator(store: InMemoryAccountStore(accounts: [account])),
            defaults: ScratchDefaults.make()
        )
        let store = try MailStore.inMemory()
        _ = try await store.upsertMailboxes([
            SignatureSettingsTests.mailbox(id: "mb_acme", address: "sales@acme.co", domainID: "dom_acme"),
            SignatureSettingsTests.mailbox(id: "mb_nw", address: "team@northwind.io", domainID: "dom_nw"),
        ], accountID: account.id)
        await environment.install(account: account, api: FakeMailAPIClient(), store: store, select: true)
        let mail = try #require(environment.graphs[account.id]?.mail)
        await mail.reloadMailboxes()
        return (environment, mail, account.id)
    }
}
