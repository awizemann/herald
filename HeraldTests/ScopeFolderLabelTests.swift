import Foundation
import HeraldKit
import Testing
@testable import Herald

/// The redesign's navigation model (R3a): scope, folder and label are three
/// INDEPENDENT axes; a domain scope is a set of mailboxes; All domains leaves
/// out the domains the user hid or excluded; drafts follow the scope; and the
/// location is persisted per account.
///
/// Two domains, three mailboxes:
/// - acme.co: `mbSales`, `mbTeam`
/// - north.io: `mbOps`
/// One inbox thread per mailbox (`t_sales`, `t_team`, `t_ops`), one archived
/// thread in `mbSales` (`t_sales_arch`), and label `lbl_client` on `t_sales`,
/// `t_ops` and `t_sales_arch`.
///
/// Internal, not private: `DomainEffectsTests` (R3b) reuses the same fixture.
@MainActor
struct ScopeHarness {
    let store: MailStore
    let api: FakeMailAPIClient
    let defaults: UserDefaults
    let model: MailViewModel
    let events: AsyncStream<SyncEvent>.Continuation

    static let account = "acct"
    static let acme = "dom_acme"
    static let north = "dom_north"

    static func make(persists: Bool = false, defaults: UserDefaults? = nil) async throws -> ScopeHarness {
        let store = try MailStore.inMemory()
        let api = FakeMailAPIClient()
        let defaults = defaults ?? ScratchDefaults.make()
        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .unbounded)
        let model = MailViewModel(
            accountID: account,
            accountLabel: "Test",
            api: api,
            store: store,
            actions: MailActionService(api: api, store: store),
            events: stream,
            markReadDelay: .seconds(3_600),
            defaults: defaults,
            persistsNavigation: persists
        )
        return ScopeHarness(store: store, api: api, defaults: defaults, model: model, events: continuation)
    }

    static func mailbox(_ id: String, _ address: String, domain: String) -> Mailbox {
        Mailbox(
            id: id,
            address: address,
            addresses: [MailboxAddress(
                id: "addr_\(id)", mailboxID: id, mailDomainID: domain, address: address,
                displayName: id, receiveEnabled: true, sendEnabled: true, isPrimary: true
            )],
            displayName: id,
            isActive: true,
            accessLevel: .manager,
            createdAt: MailFixtures.epoch,
            updatedAt: MailFixtures.epoch
        )
    }

    func seed() async throws {
        try await store.upsertMailboxes([
            Self.mailbox("mbSales", "sales@acme.co", domain: Self.acme),
            Self.mailbox("mbTeam", "team@acme.co", domain: Self.acme),
            Self.mailbox("mbOps", "ops@north.io", domain: Self.north),
        ], accountID: Self.account)
        var minute = 0
        for (thread, mailbox, folder) in [
            ("t_sales", "mbSales", MailFolder.inbox),
            ("t_team", "mbTeam", .inbox),
            ("t_ops", "mbOps", .inbox),
            ("t_sales_arch", "mbSales", .archived),
        ] {
            minute += 1
            let message = MailFixtures.message(
                id: "m_\(thread)", threadID: thread, mailboxID: mailbox, folder: folder,
                subject: "About \(thread)", date: MailFixtures.epoch.addingTimeInterval(TimeInterval(minute * 60))
            )
            try await store.upsertMessages([message], accountID: Self.account)
            try await store.upsertConversations(
                [MailFixtures.conversation(message)], accountID: Self.account, mailboxID: mailbox,
                folder: folder == .archived ? .archived : .inbox
            )
        }
        try await store.replaceLabels([MailLabel(id: "lbl_client", name: "Client", color: .blue)], accountID: Self.account)
        try await store.replaceAssignments(
            labelID: "lbl_client",
            messages: ["t_sales", "t_ops", "t_sales_arch"].map { LabelRowKey(messageID: "m_\($0)", threadID: $0) },
            accountID: Self.account
        )
    }

    func draft(_ id: String, mailboxID: String?) -> Draft {
        Draft(
            id: id, version: 1, updatedAt: MailFixtures.epoch, attachments: [],
            content: DraftInput(mailboxID: mailboxID, subject: id)
        )
    }

    /// Waits for the navigation's reload (and the drafts reload it may start).
    func settle() async {
        await model.reloadTask?.value
        await model.draftTask?.value
    }

    var listed: Set<String> { Set(model.presentedConversations.map(\.id)) }

    var acmeScope: MailViewModel.Scope {
        .domain(model.domains.first { $0.name == "acme.co" }!.id)
    }
}

@MainActor
@Suite(.scratchDefaults)
struct ScopeFolderLabelTests {
    // MARK: - Independent axes

    /// Fails if a scope change resets the folder (the pre-redesign mailbox
    /// picker did not, but a scope rewrite easily would), or if the listing
    /// is not the set of the scope's mailboxes.
    @Test("The folder survives drilling in and back out, and the list follows the scope")
    func folderSurvivesScopeChanges() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()
        #expect(harness.model.domains.map(\.name) == ["acme.co", "north.io"])

        harness.model.selectFolder(.conversation(.archived))
        await harness.settle()
        #expect(harness.listed == ["t_sales_arch"])

        harness.model.selectScope(harness.acmeScope)
        await harness.settle()
        #expect(harness.model.folder == .conversation(.archived))
        #expect(harness.listed == ["t_sales_arch"])

        harness.model.selectScope(.domain(ScopeHarness.north))
        await harness.settle()
        #expect(harness.model.folder == .conversation(.archived))
        #expect(harness.listed.isEmpty)

        harness.model.selectFolder(.inbox)
        await harness.settle()
        #expect(harness.listed == ["t_ops"])

        harness.model.selectScope(.allDomains)
        await harness.settle()
        #expect(harness.model.folder == .inbox)
        #expect(harness.listed == ["t_sales", "t_team", "t_ops"])
    }

    /// The design's "Client at level 1, then open acme.co, and the list shows
    /// acme.co · Inbox filtered to Client". Fails if a scope or folder change
    /// drops the label, or if the label does not narrow with the scope.
    @Test("An open label survives drilling in and narrows with the scope")
    func labelSurvivesAndNarrows() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()

        harness.model.openLabel("lbl_client")
        await harness.settle()
        #expect(harness.listed == ["t_sales", "t_ops"], "All domains · Inbox ∩ Client")

        harness.model.selectScope(harness.acmeScope)
        await harness.settle()
        #expect(harness.model.selectedLabelID == "lbl_client")
        #expect(harness.listed == ["t_sales"], "acme.co · Inbox ∩ Client")

        harness.model.selectScope(.mailbox("mbTeam"))
        await harness.settle()
        #expect(harness.model.selectedLabelID == "lbl_client")
        #expect(harness.listed.isEmpty, "team@ has no Client thread")

        harness.model.selectScope(harness.acmeScope)
        harness.model.selectFolder(.conversation(.archived))
        await harness.settle()
        #expect(harness.listed == ["t_sales_arch"], "acme.co · Archived ∩ Client")
    }

    /// Fails if "All domains" in the sidebar keeps the label (the design says it
    /// clears it), if the plain scope setter clears it (it must not), or if the
    /// chip's × leaves it set.
    @Test("Only All domains and an explicit clear drop the label")
    func whatClearsTheLabel() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()

        harness.model.openLabel("lbl_client")
        harness.model.selectScope(.mailbox("mbSales"))
        harness.model.selectScope(.allDomains)
        #expect(harness.model.selectedLabelID == "lbl_client", "a scope change is not a clear")

        harness.model.selectScope(.mailbox("mbSales"))
        harness.model.selectAllDomains()
        #expect(harness.model.selectedLabelID == nil)
        #expect(harness.model.scope == .allDomains)

        harness.model.openLabel("lbl_client")
        harness.model.clearLabel()
        #expect(harness.model.selectedLabelID == nil)
    }

    // MARK: - All domains exclusions

    /// Fails if All domains ignores `hidden` or `includeInAll`, or if the
    /// unfiltered fast path (`nil`) is lost when nothing is excluded.
    @Test("All domains leaves out hidden and not-included domains")
    func allDomainsHonoursExclusions() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()
        #expect(harness.model.mailboxIDs(for: .allDomains) == nil, "nothing excluded → every mailbox")
        #expect(harness.listed == ["t_sales", "t_team", "t_ops"])

        DomainPreferences.setIncludeInAll(
            false, accountID: ScopeHarness.account, domainID: ScopeHarness.north, in: harness.defaults
        )
        #expect(harness.model.mailboxIDs(for: .allDomains) == ["mbSales", "mbTeam"])
        await harness.model.reloadConversations()
        #expect(harness.listed == ["t_sales", "t_team"])
        #expect(harness.model.folderUnreadCounts[.inbox] == 2, "the folder badge counts the same set")
        #expect(harness.model.allDomainsInboxUnread == 2, "the All domains count leaves the excluded domain out")
        #expect(harness.model.badgeInboxUnread == 3, "includeInAll does not touch the Dock badge")
        // The excluded domain is still reachable on its own.
        #expect(harness.model.mailboxIDs(for: .domain(ScopeHarness.north)) == ["mbOps"])

        DomainPreferences.setIncludeInAll(
            true, accountID: ScopeHarness.account, domainID: ScopeHarness.north, in: harness.defaults
        )
        DomainPreferences.setHidden(
            true, accountID: ScopeHarness.account, domainID: ScopeHarness.acme, in: harness.defaults
        )
        await harness.model.reloadConversations()
        #expect(harness.listed == ["t_ops"])
    }

    // MARK: - Drafts

    /// Fails if a draft with no mailbox is dropped from All domains, leaks into
    /// a domain or mailbox scope, or if a narrower scope lists another
    /// mailbox's drafts. The badge must agree with the list.
    @Test("Drafts follow the scope; only All domains lists mailbox-less drafts")
    func draftsFollowTheScope() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        try await harness.store.reconcileDrafts([
            harness.draft("d_sales", mailboxID: "mbSales"),
            harness.draft("d_ops", mailboxID: "mbOps"),
            harness.draft("d_none", mailboxID: nil),
        ], accountID: ScopeHarness.account)
        await harness.model.start()

        harness.model.selectFolder(.drafts)
        await harness.settle()
        #expect(Set(harness.model.drafts.map(\.id)) == ["d_sales", "d_ops", "d_none"])
        #expect(harness.model.draftCount == 3)

        harness.model.selectScope(harness.acmeScope)
        await harness.settle()
        #expect(harness.model.folder == .drafts, "the folder survives the scope change")
        #expect(harness.model.drafts.map(\.id) == ["d_sales"])
        #expect(harness.model.draftCount == 1)

        harness.model.selectScope(.mailbox("mbTeam"))
        await harness.settle()
        #expect(harness.model.drafts.isEmpty)
        #expect(harness.model.draftCount == 0)

        // All domains with a domain excluded still lists the unassigned draft.
        DomainPreferences.setHidden(
            true, accountID: ScopeHarness.account, domainID: ScopeHarness.north, in: harness.defaults
        )
        harness.model.selectScope(.allDomains)
        await harness.settle()
        #expect(Set(harness.model.drafts.map(\.id)) == ["d_sales", "d_none"])
    }

    // MARK: - Server search

    /// The API filters by at most one mailbox. Fails if a domain search is sent
    /// scoped to one mailbox (missing the others) or unfiltered client-side
    /// (showing other domains' threads), or if a mailbox search stops sending
    /// its id.
    @Test("Domain search asks every mailbox and keeps only the domain's rows")
    func domainSearchIsFilteredClientSide() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()
        let remote = [("r_team", "mbTeam"), ("r_ops", "mbOps"), ("r_sales", "mbSales")].map { thread, mailbox in
            MailFixtures.conversation(MailFixtures.message(
                id: "m_\(thread)", threadID: thread, mailboxID: mailbox, subject: "zulu \(thread)"
            ))
        }
        await harness.api.setConversationPage(ConversationPage(conversations: remote, nextCursor: nil, totalCount: nil))

        harness.model.selectScope(harness.acmeScope)
        await harness.settle()
        harness.model.searchQuery = "zulu"
        harness.model.submitSearch()
        await harness.model.serverSearchTask?.value
        #expect(await harness.api.searches().last?.mailboxID == nil, "a domain is several mailboxes")
        #expect(harness.listed == ["r_team", "r_sales"])

        harness.model.selectScope(.mailbox("mbOps"))
        harness.model.searchQuery = "zulu "
        harness.model.submitSearch()
        await harness.model.serverSearchTask?.value
        #expect(await harness.api.searches().last?.mailboxID == "mbOps")

        DomainPreferences.setHidden(
            true, accountID: ScopeHarness.account, domainID: ScopeHarness.north, in: harness.defaults
        )
        harness.model.selectScope(.allDomains)
        harness.model.searchQuery = "zulu"
        harness.model.submitSearch()
        await harness.model.serverSearchTask?.value
        #expect(await harness.api.searches().last?.mailboxID == nil)
        #expect(!harness.listed.contains("r_ops"), "All domains leaves out the hidden domain's hits too")
        #expect(harness.listed.isSuperset(of: ["r_team", "r_sales"]))
    }

    // MARK: - Change feed

    /// Fails if the change-feed scope check still compares ONE mailbox id: in a
    /// domain scope a change to one of its mailboxes must reload, a change to
    /// another domain must not.
    @Test("A change inside the domain reloads the list; one outside does not")
    func changeFeedHonoursDomainScope() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()
        harness.model.selectScope(harness.acmeScope)
        await harness.settle()
        let baseline = harness.model.conversationReloadCount

        // The out-of-domain change, then a pass end: `.finished` stamps
        // `lastSyncedAt`, which is how the test knows the change before it was
        // consumed (events are handled in order) without a reload to wait for.
        #expect(harness.model.lastSyncedAt == nil)
        harness.events.yield(.changed(ChangeSet(updated: ["m_t_ops"])))
        harness.events.yield(.finished)
        try await wait("the out-of-domain change to be consumed") { harness.model.lastSyncedAt != nil }
        #expect(harness.model.conversationReloadCount == baseline, "north.io is not in acme.co")

        let changed = MailFixtures.message(
            id: "m_t_team", threadID: "t_team", mailboxID: "mbTeam", subject: "Changed",
            date: MailFixtures.epoch.addingTimeInterval(600)
        )
        try await harness.store.upsertMessages([changed], accountID: ScopeHarness.account)
        try await harness.store.upsertConversations(
            [MailFixtures.conversation(changed)], accountID: ScopeHarness.account, mailboxID: "mbTeam", folder: .inbox
        )

        harness.events.yield(.changed(ChangeSet(updated: ["m_t_team"])))
        try await wait("the in-domain change to reload") {
            harness.model.presentedConversations.contains { $0.latest.subject == "Changed" }
        }
        #expect(harness.model.conversationReloadCount == baseline + 1)
    }
}

// MARK: - Persistence

@MainActor
@Suite(.scratchDefaults)
struct NavigationPersistenceTests {
    /// Fails if any axis is not written, or not read back, per account.
    @Test("Scope, folder and label are persisted per account and restored at launch")
    func roundTripsThroughLaunch() async throws {
        let defaults = ScratchDefaults.make()
        let first = try await ScopeHarness.make(persists: true, defaults: defaults)
        try await first.seed()
        await first.model.start()
        first.model.selectScope(first.acmeScope)
        first.model.selectFolder(.conversation(.archived))
        first.model.openLabel("lbl_client")
        let left = first.model.location

        // Another account's key space is untouched.
        #expect(NavigationPersistence.load(accountID: "other", from: defaults) == .launchDefault)

        let relaunch = try await ScopeHarness.make(persists: true, defaults: defaults)
        try await relaunch.seed()
        await relaunch.model.start()
        #expect(relaunch.model.location == left)
        #expect(relaunch.listed == ["t_sales_arch"])
    }

    /// Fails if a model that does not persist still writes (every other
    /// view-model test shares `.standard` and an account id), or reads.
    @Test("Persistence is off unless asked for")
    func offByDefault() async throws {
        let harness = try await ScopeHarness.make(persists: false)
        try await harness.seed()
        NavigationPersistence.save(
            .init(scope: .mailbox("mbOps"), folder: .drafts, labelID: nil),
            accountID: ScopeHarness.account, to: harness.defaults
        )
        await harness.model.start()
        #expect(harness.model.location == .launchDefault, "nothing restored")
        harness.model.selectFolder(.conversation(.trash))
        #expect(NavigationPersistence.load(accountID: ScopeHarness.account, from: harness.defaults).folder == .drafts)
    }

    /// The one-time migration of the pre-redesign picker key. Fails if a
    /// stored mailbox is not carried over, if "" does not mean All domains, if
    /// the legacy key survives (it would re-run), or if it overrides a scope the
    /// new code already stored.
    @Test("The legacy picked mailbox migrates once to a scope", arguments: [
        ("mbSales", MailViewModel.Scope.mailbox("mbSales")),
        ("", MailViewModel.Scope.allDomains),
    ])
    func legacyMailboxMigrates(legacy: String, expected: MailViewModel.Scope) {
        let defaults = ScratchDefaults.make()
        let legacyKey = NavigationPersistence.legacyMailboxKey(accountID: "acct")
        #expect(legacyKey == "sidebar.mailbox.acct", "the key the old sidebar wrote")
        defaults.set(legacy, forKey: legacyKey)

        let loaded = NavigationPersistence.load(accountID: "acct", from: defaults)
        #expect(loaded.scope == expected)
        #expect(loaded.folder == .inbox)
        #expect(defaults.string(forKey: legacyKey) == nil, "migrated once, then gone")

        // A stored new-style scope wins over a leftover legacy key.
        defaults.set("mbTeam", forKey: legacyKey)
        #expect(NavigationPersistence.load(accountID: "acct", from: defaults).scope == expected)
        #expect(defaults.string(forKey: legacyKey) == nil)
    }

    /// Fails if a restored scope whose domain/mailbox is gone, or a label that
    /// is gone, strands the user on a list that can never fill — or if a
    /// correct restore is "corrected".
    @Test("A stale restored domain, mailbox or label falls back")
    func staleRestoreFallsBack() async throws {
        let defaults = ScratchDefaults.make()
        NavigationPersistence.save(
            .init(scope: .domain("dom_gone"), folder: .conversation(.sent), labelID: "lbl_gone"),
            accountID: ScopeHarness.account, to: defaults
        )
        let harness = try await ScopeHarness.make(persists: true, defaults: defaults)
        try await harness.seed()
        await harness.model.start()
        #expect(harness.model.location == .init(scope: .allDomains, folder: .conversation(.sent), labelID: nil))
        #expect(NavigationPersistence.load(accountID: ScopeHarness.account, from: defaults) == harness.model.location)

        NavigationPersistence.save(
            .init(scope: .mailbox("mbGone"), folder: .inbox, labelID: "lbl_client"),
            accountID: ScopeHarness.account, to: defaults
        )
        // A fresh, unseeded store: a cold cache. It cannot judge the scope, so
        // the scope is kept; the label is judged against the (empty) label
        // list and dropped.
        let again = try await ScopeHarness.make(persists: true, defaults: defaults)
        await again.model.start()
        #expect(again.model.scope == .mailbox("mbGone"))
        #expect(again.model.selectedLabelID == nil)
    }

    /// Fails if an id containing the prefix separator (MailDomain's fallback
    /// ids do: `domain-name:acme.co`) does not round-trip, or a malformed value
    /// is decoded as something rather than ignored.
    @Test("Scope and folder encodings round-trip and reject garbage")
    func encodings() {
        for scope: MailViewModel.Scope in [.allDomains, .domain("domain-name:acme.co"), .mailbox("mb:1")] {
            #expect(NavigationPersistence.scope(from: NavigationPersistence.raw(for: scope)) == scope)
        }
        for folder: MailViewModel.Folder in [.drafts, .inbox, .conversation(.starred), .conversation(.trash)] {
            #expect(NavigationPersistence.folder(from: NavigationPersistence.raw(for: folder)) == folder)
        }
        #expect(NavigationPersistence.scope(from: "domain:") == nil)
        #expect(NavigationPersistence.scope(from: "bogus") == nil)
        #expect(NavigationPersistence.folder(from: "bogus") == nil)
    }
}
