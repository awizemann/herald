import AppKit
import Foundation
import HeraldKit
import Testing
@testable import Herald

/// Redesign R3b — what the per-domain preferences do beyond the listing:
/// unread aggregation, per-folder label counts, the Dock badge, new-mail
/// banners and where a banner click lands, plus the preference hygiene that
/// came with retiring per-mailbox colours.
///
/// Uses ``ScopeHarness``'s fixture: acme.co (`mbSales`, `mbTeam`) and north.io
/// (`mbOps`); one unread inbox thread per mailbox, an archived `t_sales_arch`,
/// and `lbl_client` on `t_sales`, `t_ops` and `t_sales_arch`.
@MainActor
@Suite(.scratchDefaults)
struct DomainEffectsTests {
    // MARK: - Unread aggregation

    /// Fails if a domain's count is not the sum of its own mailboxes, if a
    /// thread is counted in two domains, if All domains ignores `includeInAll`
    /// or `hidden`, or if the counts follow the listed folder (N6: they are
    /// Inbox, always).
    @Test("Per-domain and All domains unread honour the exclusions")
    func aggregationWithExclusions() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        // A second unread inbox thread in acme's mbTeam: acme = 3, north = 1.
        let extra = MailFixtures.message(id: "m_team2", threadID: "t_team2", mailboxID: "mbTeam")
        try await harness.store.upsertMessages([extra], accountID: ScopeHarness.account)
        try await harness.store.upsertConversations(
            [MailFixtures.conversation(extra)], accountID: ScopeHarness.account, mailboxID: "mbTeam", folder: .inbox
        )
        await harness.model.start()
        let model = harness.model

        #expect(model.inboxUnreadByDomain == [ScopeHarness.acme: 3, ScopeHarness.north: 1])
        #expect(model.allDomainsInboxUnread == 4)
        #expect(model.badgeInboxUnread == 4)

        // N6: the sidebar counts stay Inbox under another folder.
        model.selectFolder(.conversation(.archived))
        await harness.settle()
        #expect(model.inboxUnreadByDomain[ScopeHarness.acme] == 3)
        #expect(model.allDomainsInboxUnread == 4)

        // Out of All domains: north's row keeps its own count, the total drops it.
        DomainPreferences.setIncludeInAll(false, accountID: ScopeHarness.account, domainID: ScopeHarness.north, in: harness.defaults)
        await model.domainPreferencesDidChange()
        #expect(model.inboxUnreadByDomain[ScopeHarness.north] == 1)
        #expect(model.allDomainsInboxUnread == 3)

        // Hidden as well: acme leaves the total too.
        DomainPreferences.setIncludeInAll(true, accountID: ScopeHarness.account, domainID: ScopeHarness.north, in: harness.defaults)
        DomainPreferences.setHidden(true, accountID: ScopeHarness.account, domainID: ScopeHarness.acme, in: harness.defaults)
        await model.domainPreferencesDidChange()
        #expect(model.allDomainsInboxUnread == 1)
        #expect(model.badgeInboxUnread == 1, "a hidden domain never counts toward the badge")
    }

    /// The pure tally. Thread `t_shared` has an unread inbox row in BOTH of
    /// acme's mailboxes and one in north's; `t_arch` is listed in the inbox
    /// but locally archived. Fails on the old per-mailbox sum (acme 3, All
    /// domains 4 — the shared thread counted per row), if a mailbox the
    /// domain does not own leaks in, if a zero domain is reported, if the
    /// archived row counts in the Inbox, or if an explicit All domains set
    /// drops the unassigned row.
    @Test("Aggregated unread counts distinct threads, per the folder rule")
    func tallyCountsDistinctThreads() {
        func key(_ thread: String, _ mailbox: String, _ list: ConversationFolder = .inbox, _ folder: MailFolder = .inbox) -> UnreadConversationKey {
            UnreadConversationKey(threadID: thread, mailboxKey: mailbox, listFolder: list.rawValue, folderRaw: folder.rawValue)
        }
        let keys = [
            key("t_shared", "a"), key("t_shared", "b"), key("t_shared", "c"),
            key("t_a", "a"),
            key("t_arch", "b", .inbox, .archived),
            key("t_arch", "b", .archived, .archived),
            key("t_loose", ""),
            key("t_stray", "stray"),
        ]
        let acme = MailDomain(id: "d1", name: "acme.co", mailboxIDs: ["a", "b"])
        let north = MailDomain(id: "d2", name: "north.io", mailboxIDs: ["c"])
        let quiet = MailDomain(id: "d3", name: "quiet.io", mailboxIDs: ["q"])
        let tally = UnreadTally(
            keys: keys, scopeIDs: ["a", "b"], folders: [.inbox, .archived],
            mailboxIDs: ["a", "b", "c", "q"], domains: [acme, north, quiet],
            allDomainIDs: ["a", "b", ""], badgeIDs: nil
        )
        #expect(tally.byMailbox == ["a": 2, "b": 1, "c": 1])
        #expect(tally.byDomain == ["d1": 2, "d2": 1])
        #expect(tally.byFolder == [.inbox: 2, .archived: 1], "acme scope: t_shared + t_a; the archived row counts only there")
        #expect(tally.allDomains == 3, "t_shared, t_a and the unassigned t_loose — once each")
        #expect(tally.badge == 4, "nil = every row: t_shared, t_a, t_loose, t_stray — once each")
    }

    // MARK: - Label counts per folder

    /// Fails on the old behaviour (3 everywhere — counted across every folder
    /// and mailbox), if the count ignores the scope, or if Drafts counts
    /// something other than where a label click from Drafts lands (Inbox).
    @Test("Label badges count the current folder and scope")
    func labelCountsFollowFolderAndScope() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()
        let model = harness.model

        #expect(model.threadCount(forLabel: "lbl_client") == 2, "All domains · Inbox: t_sales + t_ops")

        model.selectFolder(.conversation(.archived))
        await harness.settle()
        #expect(model.threadCount(forLabel: "lbl_client") == 1, "All domains · Archived: t_sales_arch")

        model.selectScope(harness.acmeScope)
        model.selectFolder(.conversation(.inbox))
        await harness.settle()
        #expect(model.threadCount(forLabel: "lbl_client") == 1, "acme.co · Inbox: t_sales")

        // The badge agrees with what opening the label lists.
        model.openLabel("lbl_client")
        await harness.settle()
        #expect(harness.listed.count == model.threadCount(forLabel: "lbl_client"))
        model.clearLabel()

        model.selectAllDomains()
        model.selectFolder(.drafts)
        await harness.settle()
        #expect(model.threadCount(forLabel: "lbl_client") == 2, "under Drafts the badge counts the Inbox")

        // All domains' exclusions narrow the count like they narrow the list.
        model.selectFolder(.conversation(.inbox))
        DomainPreferences.setIncludeInAll(false, accountID: ScopeHarness.account, domainID: ScopeHarness.north, in: harness.defaults)
        await model.domainPreferencesDidChange()
        #expect(model.threadCount(forLabel: "lbl_client") == 1)
    }

    // MARK: - Dock badge

    private static func account(_ host: String) -> Account {
        Account(origin: URL(string: "https://\(host)")!, clientID: "cid", scopes: [])
    }

    /// acme.co + north.io, one unread inbox thread per mailbox (3 in all).
    private static func seedAccount(_ store: MailStore, _ account: Account) async throws {
        try await store.upsertMailboxes([
            ScopeHarness.mailbox("mbSales", "sales@acme.co", domain: ScopeHarness.acme),
            ScopeHarness.mailbox("mbTeam", "team@acme.co", domain: ScopeHarness.acme),
            ScopeHarness.mailbox("mbOps", "ops@north.io", domain: ScopeHarness.north),
        ], accountID: account.id)
        for mailbox in ["mbSales", "mbTeam", "mbOps"] {
            let message = MailFixtures.message(id: "m_\(mailbox)", threadID: "t_\(mailbox)", mailboxID: mailbox)
            try await store.upsertMessages([message], accountID: account.id)
            try await store.upsertConversations(
                [MailFixtures.conversation(message)], accountID: account.id, mailboxID: mailbox, folder: .inbox
            )
        }
    }

    /// Fails if the badge ignores `countInBadge` or `hidden`, if a preference of
    /// one account leaks into the other (same domain ids in both), if the sum
    /// across accounts is lost, if `includeInAll` is mistaken for the badge
    /// switch, or if the global Dock switch stops winning.
    @Test("The Dock badge honours countInBadge and hidden across two accounts")
    func badgeAcrossAccounts() async throws {
        let defaults = ScratchDefaults.make()
        let environment = AppEnvironment(defaults: defaults, notificationPoster: SilentCenter())
        let store = try MailStore.inMemory()
        let first = Self.account("a.example.com")
        let second = Self.account("b.example.com")
        try await Self.seedAccount(store, first)
        try await Self.seedAccount(store, second)
        await environment.install(account: first, api: FakeMailAPIClient(), store: store)
        await environment.install(account: second, api: FakeMailAPIClient(), store: store, select: false)
        #expect(environment.totalUnreadCount == 6)

        // First account: north.io out of the badge (1). Second: acme.co hidden
        // (2) and north.io out of All domains — which the badge ignores.
        DomainPreferences.setCountInBadge(false, accountID: first.id, domainID: ScopeHarness.north, in: defaults)
        DomainPreferences.setHidden(true, accountID: second.id, domainID: ScopeHarness.acme, in: defaults)
        DomainPreferences.setIncludeInAll(false, accountID: second.id, domainID: ScopeHarness.north, in: defaults)
        for id in [first.id, second.id] { await environment.graphs[id]?.mail.domainPreferencesDidChange() }

        #expect(environment.graphs[first.id]?.mail.badgeInboxUnread == 2)
        #expect(environment.graphs[second.id]?.mail.badgeInboxUnread == 1)
        #expect(environment.totalUnreadCount == 3)
        // The account list shows All domains, not the badge share.
        #expect(environment.unreadCount(forAccount: first.id) == 3)
        #expect(environment.unreadCount(forAccount: second.id) == 0)

        let tile = NSApplication.shared.dockTile
        let previous = tile.badgeLabel
        defer { tile.badgeLabel = previous }
        environment.applyDockBadge()
        #expect(tile.badgeLabel == "3")
        defaults.set(false, forKey: NotificationSettings.dockBadgeKey)
        environment.applyDockBadge()
        #expect(tile.badgeLabel == nil || tile.badgeLabel?.isEmpty == true)
    }

    // MARK: - Notifications

    /// The rule table on its own. Fails if `notify == nil` silences, if an
    /// explicit `false` or `hidden` does not, or if one domain's switch
    /// silences another's mailboxes.
    @Test("Silenced mailboxes: hidden or notify off; nil and true follow the global switch")
    func silencedMailboxRules() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()
        let model = harness.model
        #expect(model.notificationSilencedMailboxIDs().isEmpty)

        DomainPreferences.setNotify(true, accountID: ScopeHarness.account, domainID: ScopeHarness.acme, in: harness.defaults)
        DomainPreferences.setNotify(false, accountID: ScopeHarness.account, domainID: ScopeHarness.north, in: harness.defaults)
        // What `AppEnvironment.updateDomainPreferences` follows every write
        // with — the resolved sets are cached until it runs.
        await model.domainPreferencesDidChange()
        #expect(model.notificationSilencedMailboxIDs() == ["mbOps"])

        DomainPreferences.setHidden(true, accountID: ScopeHarness.account, domainID: ScopeHarness.acme, in: harness.defaults)
        await model.domainPreferencesDidChange()
        #expect(model.notificationSilencedMailboxIDs() == ["mbOps", "mbSales", "mbTeam"], "hidden beats notify = true")
    }

    /// End to end through the sync event stream: fails if a silenced domain
    /// posts, if silencing leaks to the other domain, or if an explicit
    /// per-domain `true` overrides the global switch being OFF.
    @Test("New-mail banners honour per-domain notify and hidden under the global switch")
    func bannersHonourDomainSwitches() async throws {
        let store = try MailStore.inMemory()
        let defaults = ScratchDefaults.make()
        let center = RecordingBannerCenter()
        let api = FakeMailAPIClient()
        let (stream, events) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .unbounded)
        try await store.upsertMailboxes([
            ScopeHarness.mailbox("mbSales", "sales@acme.co", domain: ScopeHarness.acme),
            ScopeHarness.mailbox("mbOps", "ops@north.io", domain: ScopeHarness.north),
        ], accountID: ScopeHarness.account)
        let model = MailViewModel(
            accountID: ScopeHarness.account, accountLabel: "Test", api: api, store: store,
            actions: MailActionService(api: api, store: store), events: stream,
            markReadDelay: .seconds(3_600), defaults: defaults,
            notifier: NewMailNotifier(center: center, lookup: store)
        )
        await model.start()
        /// One whole pass, CONSUMED before returning — `.began` is awaited as
        /// `.syncing` and `.finished` as `.idle` — so a setting flipped right
        /// after cannot race the pass it was meant to follow.
        func arrive(_ id: String, in mailbox: String) async throws {
            try await store.upsertMessages(
                [MailFixtures.message(id: id, threadID: "t_\(id)", mailboxID: mailbox)], accountID: ScopeHarness.account
            )
            events.yield(.began)
            try await wait("the pass to begin") { model.status == .syncing }
            events.yield(.changed(ChangeSet(inserted: [id])))
            events.yield(.finished)
            try await wait("the pass to be consumed") { model.status == .idle }
        }
        func posted() async -> [String] { await center.posted.compactMap(\.messageID) }

        // north.io notify OFF: its mail is silent, acme's (nil → global ON) posts.
        DomainPreferences.setNotify(false, accountID: ScopeHarness.account, domainID: ScopeHarness.north, in: defaults)
        await model.domainPreferencesDidChange()
        try await arrive("ops1", in: "mbOps")
        try await arrive("sales1", in: "mbSales")
        try await wait("acme's banner") { await posted().count == 1 }
        #expect(await posted() == ["sales1"])

        // acme hidden, north back ON explicitly.
        DomainPreferences.setHidden(true, accountID: ScopeHarness.account, domainID: ScopeHarness.acme, in: defaults)
        DomainPreferences.setNotify(true, accountID: ScopeHarness.account, domainID: ScopeHarness.north, in: defaults)
        await model.domainPreferencesDidChange()
        try await arrive("sales2", in: "mbSales")
        try await arrive("ops2", in: "mbOps")
        try await wait("north's banner") { await posted().count == 2 }
        #expect(await posted() == ["sales1", "ops2"])

        // Global OFF is the master: north's explicit `true` does not override it.
        defaults.set(false, forKey: NotificationSettings.newMailKey)
        try await arrive("ops3", in: "mbOps")
        defaults.set(true, forKey: NotificationSettings.newMailKey)
        try await arrive("ops4", in: "mbOps")
        try await wait("the control banner") { await posted().count == 3 }
        #expect(await posted() == ["sales1", "ops2", "ops4"])
        model.stop()
    }

    // MARK: - Notification click routing

    /// Fails if a click on a thread in a domain kept out of All domains resets
    /// to All domains (where the thread can never be listed, so nothing is
    /// selected), or if a reachable thread stops landing on All domains.
    @Test("A banner click lands in the thread's own domain when All domains leaves it out")
    func clickRoutesIntoAnExcludedDomain() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        DomainPreferences.setIncludeInAll(false, accountID: ScopeHarness.account, domainID: ScopeHarness.north, in: harness.defaults)
        await harness.model.start()
        let model = harness.model
        model.selectFolder(.conversation(.archived))
        await harness.settle()

        await model.revealConversation(threadID: "t_ops")
        #expect(model.scope == .domain(ScopeHarness.north))
        #expect(model.folder == .conversation(.inbox))
        #expect(model.selectedThreadID == "t_ops")

        await model.revealConversation(threadID: "t_sales")
        #expect(model.scope == .allDomains)
        #expect(model.selectedThreadID == "t_sales")

        // A hidden domain is never a landing place (it never notifies; a banner
        // older than the hide finds nothing rather than reopening it).
        DomainPreferences.setHidden(true, accountID: ScopeHarness.account, domainID: ScopeHarness.north, in: harness.defaults)
        await model.revealConversation(threadID: "t_ops")
        #expect(model.scope == .allDomains)
        #expect(model.selectedThreadID != "t_ops")
    }

    // MARK: - Server-disabled mailboxes and domains

    /// `ScopeHarness`'s mailbox with the two server switches set.
    private static func mailbox(
        _ id: String, _ address: String, domain: String, isActive: Bool = true, domainEnabled: Bool = true
    ) -> Mailbox {
        let base = ScopeHarness.mailbox(id, address, domain: domain)
        let primary = base.addresses[0]
        return Mailbox(
            id: base.id,
            address: base.address,
            addresses: [MailboxAddress(
                id: primary.id, mailboxID: primary.mailboxID, mailDomainID: primary.mailDomainID,
                address: primary.address, displayName: primary.displayName,
                receiveEnabled: primary.receiveEnabled, sendEnabled: primary.sendEnabled,
                isPrimary: primary.isPrimary, domainEnabled: domainEnabled
            )],
            displayName: base.displayName,
            isActive: isActive,
            accessLevel: base.accessLevel,
            createdAt: base.createdAt,
            updatedAt: base.updatedAt
        )
    }

    /// Rewrites the fixture's three mailboxes with the given switches, the way
    /// a sync pass would after the owner flips them on the server. Returns the
    /// store's own change set — what the engine would emit as `.changed`.
    @discardableResult
    private static func setServerSwitches(
        _ store: MailStore,
        teamActive: Bool = true,
        northEnabled: Bool = true
    ) async throws -> ChangeSet {
        try await store.upsertMailboxes([
            mailbox("mbSales", "sales@acme.co", domain: ScopeHarness.acme),
            mailbox("mbTeam", "team@acme.co", domain: ScopeHarness.acme, isActive: teamActive),
            mailbox("mbOps", "ops@north.io", domain: ScopeHarness.north, domainEnabled: northEnabled),
        ], accountID: ScopeHarness.account)
    }

    /// A mailbox switched off at the server (`isActive == false`) in a domain
    /// that keeps another, active one. Fails if the disabled mailbox stays in
    /// its domain, the counts or the badge; if the All domains listing keeps
    /// its mail (the store's "every mailbox" fast path would, with no domain
    /// excluded); or if it can still post a banner.
    @Test("An inactive mailbox leaves its domain, the counts, the listing and notifications")
    func inactiveMailboxIsExcluded() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        try await Self.setServerSwitches(harness.store, teamActive: false)
        await harness.model.start()
        let model = harness.model

        #expect(model.domains.map(\.name) == ["acme.co", "north.io"], "acme keeps its active mailbox")
        #expect(model.domains.first { $0.id == ScopeHarness.acme }?.mailboxIDs == ["mbSales"])
        #expect(!model.mailboxes.contains { $0.id == "mbTeam" })
        #expect(model.inboxUnreadByDomain == [ScopeHarness.acme: 1, ScopeHarness.north: 1])
        #expect(model.allDomainsInboxUnread == 2)
        #expect(model.badgeInboxUnread == 2)
        #expect(harness.listed == ["t_sales", "t_ops"])
        #expect(model.notificationSilencedMailboxIDs() == ["mbTeam"])
    }

    /// The flip arriving through the sync feed, as the store reports it (the
    /// change names only the mailbox row). All domains stays a valid scope, so
    /// no scope correction reloads it. Fails if the disabled mailbox's thread
    /// and draft stay listed after the pass, or stay missing after re-enabling.
    @Test("A server-side flip through the change feed reloads the list and drafts")
    func changeFeedFlipReloadsListing() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        try await harness.store.reconcileDrafts([
            harness.draft("d_sales", mailboxID: "mbSales"),
            harness.draft("d_team", mailboxID: "mbTeam"),
        ], accountID: ScopeHarness.account)
        await harness.model.start()
        let model = harness.model
        #expect(harness.listed == ["t_sales", "t_team", "t_ops"])
        #expect(model.draftCount == 2)

        let off = try await Self.setServerSwitches(harness.store, teamActive: false)
        #expect(off.updated == ["mbTeam"])
        harness.events.yield(.changed(off))
        try await wait("the disabled mailbox to leave the list") {
            harness.listed == ["t_sales", "t_ops"] && model.draftCount == 1
        }
        #expect(model.scope == .allDomains)
        #expect(model.allDomainsInboxUnread == 2)

        harness.events.yield(.changed(try await Self.setServerSwitches(harness.store)))
        try await wait("the re-enabled mailbox to come back") {
            harness.listed == ["t_sales", "t_team", "t_ops"] && model.draftCount == 2
        }
        #expect(model.allDomainsInboxUnread == 3)
    }

    /// The pass that disables a mailbox can also carry new mail for it; the
    /// banner is decided before the list reloads. Fails if that mail posts.
    /// The acme message in the same pass is the control that proves the pass
    /// was consumed.
    @Test("Mail arriving in the pass that disables its mailbox posts no banner")
    func noBannerForMailboxDisabledInSamePass() async throws {
        let store = try MailStore.inMemory()
        let defaults = ScratchDefaults.make()
        let center = RecordingBannerCenter()
        let api = FakeMailAPIClient()
        let (stream, events) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .unbounded)
        try await Self.setServerSwitches(store)
        let model = MailViewModel(
            accountID: ScopeHarness.account, accountLabel: "Test", api: api, store: store,
            actions: MailActionService(api: api, store: store), events: stream,
            markReadDelay: .seconds(3_600), defaults: defaults,
            notifier: NewMailNotifier(center: center, lookup: store)
        )
        await model.start()

        var pass = try await Self.setServerSwitches(store, teamActive: false)
        try await store.upsertMessages([
            MailFixtures.message(id: "team1", threadID: "t_team1", mailboxID: "mbTeam"),
            MailFixtures.message(id: "sales1", threadID: "t_sales1", mailboxID: "mbSales"),
        ], accountID: ScopeHarness.account)
        pass.inserted.formUnion(["team1", "sales1"])
        events.yield(.changed(pass))
        try await wait("the control banner") { await center.posted.count == 1 }
        #expect(await center.posted.compactMap(\.messageID) == ["sales1"])
        model.stop()
    }

    /// The domain's own switch (`domainEnabled == false` on its addresses).
    /// Fails if the flag is ignored, or if a domain with no enabled mailbox
    /// left still gets a row. The other fixture mailboxes carry the default
    /// (`true`, what an older server's absent field decodes to) and must stay.
    @Test("A disabled domain disappears with all of its mailboxes")
    func disabledDomainIsExcluded() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        try await Self.setServerSwitches(harness.store, northEnabled: false)
        await harness.model.start()
        let model = harness.model

        #expect(model.domains.map(\.name) == ["acme.co"])
        #expect(model.allDomainsInboxUnread == 2)
        #expect(model.badgeInboxUnread == 2)
        #expect(harness.listed == ["t_sales", "t_team"])
        #expect(model.notificationSilencedMailboxIDs() == ["mbOps"])
    }

    /// Mirrors `hideDomain`: a window standing in what the server just switched
    /// off falls back to All domains, keeping its folder. Fails if the scope
    /// is left on a mailbox or domain that no longer exists in the sidebar.
    @Test("A scope inside a mailbox or domain the server disabled falls back to All domains")
    func scopeFallsBackWhenDisabled() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()
        let model = harness.model

        model.selectScope(.mailbox("mbTeam"))
        model.selectFolder(.conversation(.archived))
        await harness.settle()
        try await Self.setServerSwitches(harness.store, teamActive: false)
        await model.reloadMailboxes()
        #expect(model.scope == .allDomains)
        #expect(model.folder == .conversation(.archived))

        model.selectScope(.domain(ScopeHarness.north))
        await harness.settle()
        try await Self.setServerSwitches(harness.store, teamActive: false, northEnabled: false)
        await model.reloadMailboxes()
        #expect(model.scope == .allDomains)
    }

    /// A brand-new message has no tie to a mailbox. Fails if a composer for a
    /// disabled mailbox is still offered its address, or drafts into it under
    /// another mailbox's From.
    @Test("A new message never starts from a disabled mailbox")
    func newMessageSkipsDisabledMailbox() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        try await Self.setServerSwitches(harness.store, teamActive: false)
        await harness.model.start()
        let model = harness.model

        let context = try #require(await model.composeContext(for: ComposeRequest(kind: .new, mailboxID: "mbTeam")))
        #expect(context.fromAddress != "team@acme.co")
        #expect(context.mailboxID != "mbTeam")
        #expect(model.mailboxes.contains { $0.id == context.mailboxID && $0.address == context.fromAddress })
        // Still the user's own address: reply-all must not CC it.
        #expect(model.ownAddresses.contains("team@acme.co"))
    }

    /// A reply belongs to its mailbox. Fails if replying or forwarding from a
    /// disabled mailbox silently switches to another mailbox's identity
    /// instead of saying why it can't.
    @Test("Reply and forward from a disabled mailbox are refused, not re-addressed",
          arguments: [ComposeRequest.Kind.reply, .replyAll, .forward])
    func replyFromDisabledMailboxIsRefused(kind: ComposeRequest.Kind) async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        try await Self.setServerSwitches(harness.store, teamActive: false)
        await harness.model.start()
        let model = harness.model

        #expect(await model.composeContext(for: ComposeRequest(kind: kind, mailboxID: "mbTeam")) == nil)
        #expect(model.actionError == MailViewModel.disabledMailboxReplyError)

        model.actionError = nil
        let enabled = try #require(await model.composeContext(for: ComposeRequest(kind: kind, mailboxID: "mbSales")))
        #expect(enabled.fromAddress == "sales@acme.co")
        #expect(model.actionError == nil)
    }

    /// A stored draft of a disabled mailbox keeps a mailbox and a From that
    /// agree (the server refuses the send). Fails if its empty From is filled
    /// with ANOTHER mailbox's address.
    @Test("A stored draft of a disabled mailbox keeps its own From")
    func storedDraftOfDisabledMailboxKeepsItsFrom() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        try await harness.store.reconcileDrafts(
            [harness.draft("d_team", mailboxID: "mbTeam")], accountID: ScopeHarness.account
        )
        try await Self.setServerSwitches(harness.store, teamActive: false)
        await harness.model.start()

        let context = try #require(
            await harness.model.composeContext(for: ComposeRequest(kind: .draft, draftID: "d_team"))
        )
        #expect(context.mailboxID == "mbTeam")
        #expect(context.fromAddress == "team@acme.co")
    }

    /// acme.co and acorn.io clash at two letters (AC), so both are promoted to
    /// three. Fails if disabling acme.co at the server re-letters acorn.io to
    /// AC — in the Settings sidebar or the list rows — the promise hiding
    /// already keeps.
    @Test("A disabled domain still counts for monogram clashes")
    func disabledDomainKeepsMonogramClash() async throws {
        let harness = try await ScopeHarness.make()
        let mailboxes = [
            Self.mailbox("mbAcme", "sales@acme.co", domain: "dom_acme", domainEnabled: false),
            Self.mailbox("mbAcorn", "hi@acorn.io", domain: "dom_acorn"),
        ]
        try await harness.store.upsertMailboxes(mailboxes, accountID: ScopeHarness.account)
        await harness.model.start()
        let model = harness.model

        #expect(model.domains.map(\.id) == ["dom_acorn"])
        #expect(model.rowAttributionIndex().monograms["mbAcorn"] == "ACO")
        #expect(DomainBadgeResolver.monograms(
            for: model.monogramDomains, accountID: ScopeHarness.account, in: harness.defaults
        )["dom_acorn"] == "ACO")

        let settings = SettingsDomainItem.visible(
            mailboxes: model.monogramMailboxes, accountID: ScopeHarness.account, defaults: harness.defaults
        )
        #expect(settings.map(\.id) == ["dom_acorn"], "Settings lists no server-disabled domain")
        #expect(settings.first?.monogram == "ACO")
    }

    // MARK: - Preference hygiene

    /// Fails if the purge misses a stored override, touches a key outside
    /// `mailboxColor.`, or runs again (a key written after the first run
    /// survives — the one-time guard).
    @Test("The legacy mailbox-colour purge removes the overrides exactly once")
    func mailboxColourPurgeRunsOnce() {
        let defaults = ScratchDefaults.make()
        defaults.set("pink", forKey: "mailboxColor.https://a.example.mb1")
        defaults.set("teal", forKey: "mailboxColor.https://b.example.mb2")
        defaults.set("keep", forKey: "mailboxColorish.unrelated")
        defaults.set("all", forKey: NavigationPersistence.scopeKey(accountID: "https://a.example"))

        #expect(PreferenceHygiene.purgeLegacyMailboxColorsOnce(in: defaults))
        #expect(defaults.object(forKey: "mailboxColor.https://a.example.mb1") == nil)
        #expect(defaults.object(forKey: "mailboxColor.https://b.example.mb2") == nil)
        #expect(defaults.string(forKey: "mailboxColorish.unrelated") == "keep")
        #expect(defaults.string(forKey: NavigationPersistence.scopeKey(accountID: "https://a.example")) == "all")

        defaults.set("plum", forKey: "mailboxColor.https://a.example.mb3")
        #expect(!PreferenceHygiene.purgeLegacyMailboxColorsOnce(in: defaults))
        #expect(defaults.string(forKey: "mailboxColor.https://a.example.mb3") == "plum")
    }

    /// Writes every Herald-only key an account can own.
    private static func writeEverything(for accountID: String, in defaults: UserDefaults) {
        DomainPreferences.setHidden(true, accountID: accountID, domainID: "dom", in: defaults)
        DomainPreferences.setMonogramOverride("AB", accountID: accountID, domainID: "dom", in: defaults)
        NavigationPersistence.save(
            MailViewModel.Location(scope: .domain("dom"), folder: .conversation(.sent), labelID: "lbl"),
            accountID: accountID, to: defaults
        )
        defaults.set("mbA", forKey: NavigationPersistence.legacyMailboxKey(accountID: accountID))
        defaults.set("plum", forKey: AccountTintAssignment.storageKey(accountID: accountID))
    }

    private static func ownedKeys(for accountID: String) -> [String] {
        [
            DomainPreferences.hiddenKey(accountID: accountID, domainID: "dom"),
            DomainPreferences.hiddenAtKey(accountID: accountID, domainID: "dom"),
            DomainPreferences.monogramKey(accountID: accountID, domainID: "dom"),
            NavigationPersistence.scopeKey(accountID: accountID),
            NavigationPersistence.folderKey(accountID: accountID),
            NavigationPersistence.labelKey(accountID: accountID),
            NavigationPersistence.legacyMailboxKey(accountID: accountID),
            AccountTintAssignment.storageKey(accountID: accountID),
        ]
    }

    /// Fails if any of the account's keys survive, or if the purge reaches an
    /// account whose id merely STARTS with this one's (`https://mail.x` vs
    /// `https://mail.x.y` — the collision `DomainPreferences` escapes against).
    @Test("The sign-out purge removes one account's keys and no other's")
    func accountPurgeIsScoped() {
        let defaults = ScratchDefaults.make()
        let gone = "https://mail.x"
        let kept = "https://mail.x.y"
        Self.writeEverything(for: gone, in: defaults)
        Self.writeEverything(for: kept, in: defaults)

        PreferenceHygiene.purgeAccount(gone, from: defaults)

        for key in Self.ownedKeys(for: gone) { #expect(defaults.object(forKey: key) == nil, "\(key) survived") }
        for key in Self.ownedKeys(for: kept) { #expect(defaults.object(forKey: key) != nil, "\(key) was purged") }
    }

    /// The wiring: fails if `signOut(accountID:)` stops calling the purge, or
    /// purges the account that stays signed in.
    @Test("Signing out purges that account's Herald-only preferences")
    func signOutPurges() async throws {
        let first = Self.account("mail.test.invalid")
        let second = Self.account("mail.test.invalid.example")
        let environment = SignInRecoveryTests.environment(
            presenter: ScriptedPresenter(), store: InMemoryAccountStore(accounts: [first, second])
        )
        let store = try MailStore.inMemory()
        await environment.install(account: first, api: FakeMailAPIClient(), store: store)
        await environment.install(account: second, api: FakeMailAPIClient(), store: store, select: false)
        Self.writeEverything(for: first.id, in: environment.defaults)
        Self.writeEverything(for: second.id, in: environment.defaults)

        await environment.signOut(accountID: first.id)

        for key in Self.ownedKeys(for: first.id) { #expect(environment.defaults.object(forKey: key) == nil, "\(key) survived") }
        for key in Self.ownedKeys(for: second.id) { #expect(environment.defaults.object(forKey: key) != nil, "\(key) was purged") }
        await environment.signOut(accountID: second.id)
    }
}

/// Records banners instead of showing them.
private actor RecordingBannerCenter: NewMailNotificationPosting {
    private(set) var posted: [NewMailNotification] = []
    func requestAuthorization() async -> Bool { true }
    func post(_ notification: NewMailNotification) async { posted.append(notification) }
}

/// Grants nothing and posts nothing — for tests that only need a centre.
private struct SilentCenter: NewMailNotificationPosting {
    func requestAuthorization() async -> Bool { false }
    func post(_ notification: NewMailNotification) async {}
}
