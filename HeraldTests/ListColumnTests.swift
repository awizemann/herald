import Foundation
import HeraldKit
import Testing
@testable import Herald

/// The middle column's rules (redesign R5, handoff §2 / §3.1): attribution per
/// scope, the header's title/caption/folder menu, the search prompt, the empty
/// states, the density metrics, and the thread header's counts and own-message
/// detection. Pure rules are asserted directly; the view-model bridge is
/// asserted against the R3a scope fixture (`ScopeHarness`: acme.co = sales@,
/// team@; north.io = ops@).
@MainActor
@Suite(.scratchDefaults)
struct ListColumnTests {
    // MARK: - Attribution (§2)

    static let epoch = Date(timeIntervalSince1970: 0)

    static func mailbox(_ id: String, _ address: String, domain: String) -> Mailbox {
        ScopeHarness.mailbox(id, address, domain: domain)
    }

    static let mailboxes = [
        mailbox("mbSales", "sales@acme.co", domain: "dom_acme"),
        mailbox("mbTeam", "team@acme.co", domain: "dom_acme"),
        mailbox("mbOps", "ops@north.io", domain: "dom_north"),
    ]

    static func index(_ scope: MailViewModel.Scope, overrides: [MailDomain.ID: String] = [:]) -> ListColumn.AttributionIndex {
        ListColumn.AttributionIndex.make(
            level: .init(scope: scope), mailboxes: mailboxes,
            domains: MailDomain.domains(from: mailboxes), monogramOverrides: overrides
        )
    }

    /// The §2 rule: show only the levels the scope has not fixed. Fails if a
    /// domain scope still draws the (identical) badge on every row, if a
    /// mailbox scope draws anything, or if All domains drops either half.
    @Test("Attribution shows only what the scope leaves open")
    func attributionPerScope() {
        let all = Self.index(.allDomains).attribution(forMailbox: "mbSales")
        #expect(all.monogram == "AC")
        #expect(all.mailbox == "sales@")
        #expect(all.spoken == "sales@acme.co")

        let domain = Self.index(.domain("dom_acme")).attribution(forMailbox: "mbSales")
        #expect(domain.monogram == nil, "one domain: the badge would say the same thing on every row")
        #expect(domain.mailbox == "sales@")

        let mailbox = Self.index(.mailbox("mbSales")).attribution(forMailbox: "mbSales")
        #expect(mailbox.isEmpty)
        #expect(mailbox.spoken == nil)
    }

    /// Fails if the badge is derived per mailbox (no clash promotion) or
    /// ignores the user's monogram override.
    @Test("Badges carry the domain's resolved monogram, override included")
    func badgesUseDomainMonograms() {
        #expect(Self.index(.allDomains).attribution(forMailbox: "mbOps").monogram == "NO")
        let overridden = Self.index(.allDomains, overrides: ["dom_acme": "XY"])
        #expect(overridden.attribution(forMailbox: "mbTeam").monogram == "XY")
        #expect(overridden.attribution(forMailbox: "mbSales").monogram == "XY")
    }

    /// A draft (or message) no mailbox owns gets the "No mailbox" tag where
    /// attribution shows; a mailbox the index doesn't know yet shows nothing
    /// rather than a guess.
    @Test("No mailbox → the tag; an unknown mailbox → nothing")
    func unassignedAndUnknown() {
        let unassigned = Self.index(.allDomains).attribution(forMailbox: nil)
        #expect(unassigned.isUnassigned)
        #expect(unassigned.monogram == nil && unassigned.mailbox == nil)
        #expect(unassigned.spoken == "No mailbox")
        #expect(Self.index(.allDomains).attribution(forMailbox: "mbGhost").isEmpty)
        #expect(Self.index(.mailbox("mbSales")).attribution(forMailbox: nil).isEmpty)
    }

    @Test("Local part keeps its @; an address without one is shown whole")
    func localPart() {
        #expect(ListColumn.localPart(of: "sales@acme.co") == "sales@")
        #expect(ListColumn.localPart(of: "weird") == "weird")
    }

    // MARK: - Header, caption, search (view-model bridge)

    /// Fails if the prompt, the caption or the title kind don't follow the
    /// scope — e.g. a domain named by its id instead of its name, or a mailbox
    /// by its display name instead of its address.
    @Test("Search prompt, caption and title follow the scope and the folder")
    func headerFollowsScope() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()
        let model = harness.model

        #expect(model.searchPrompt == "Search all domains")
        #expect(model.listCaption == "All domains · Inbox")
        #expect(ListColumn.titleIsFolderMenu(model.scope))

        model.selectFolder(.conversation(.sent))
        await harness.settle()
        #expect(model.listCaption == "All domains · Sent")

        model.selectScope(harness.acmeScope)
        model.selectFolder(.inbox)
        await harness.settle()
        #expect(model.searchPrompt == "Search acme.co")
        #expect(model.listCaption == "acme.co · Inbox")
        #expect(ListColumn.titleIsFolderMenu(model.scope))

        model.selectScope(.mailbox("mbSales"))
        model.selectFolder(.drafts)
        await harness.settle()
        #expect(model.searchPrompt == "Search sales@acme.co")
        #expect(model.listCaption == "sales@acme.co · Drafts")
        #expect(ListColumn.titleIsFolderMenu(model.scope) == false, "a mailbox's title is plain text")
    }

    /// The chip claims a filter; behind Drafts the label filters nothing.
    @Test("The label chip shows with an open label, but not behind Drafts")
    func labelChipVisibility() {
        #expect(ListColumn.showsLabelChip(labelOpen: true, folder: .inbox))
        #expect(ListColumn.showsLabelChip(labelOpen: true, folder: .drafts) == false)
        #expect(ListColumn.showsLabelChip(labelOpen: false, folder: .inbox) == false)
    }

    // MARK: - Folder menu

    @Test("The folder menu lists six folders, Drafts after Sent")
    func menuOrder() {
        #expect(ListColumn.menuFolders.map(ListColumn.folderTitle) ==
            ["Inbox", "Starred", "Sent", "Drafts", "Archived", "Trash"])
    }

    /// Only Inbox (unread) and Drafts (total) carry a count; zero shows none.
    /// Fails if another folder's unread leaks in, or a zero draws "0".
    @Test("Folder menu counts: Inbox unread and Drafts total only")
    func menuCounts() {
        let unread: [ConversationFolder: Int] = [.inbox: 4, .sent: 9, .archived: 2]
        #expect(ListColumn.menuCount(for: .inbox, unreadByFolder: unread, draftCount: 3) == 4)
        #expect(ListColumn.menuCount(for: .drafts, unreadByFolder: unread, draftCount: 3) == 3)
        #expect(ListColumn.menuCount(for: .conversation(.sent), unreadByFolder: unread, draftCount: 3) == nil)
        #expect(ListColumn.menuCount(for: .conversation(.archived), unreadByFolder: unread, draftCount: 3) == nil)
        #expect(ListColumn.menuCount(for: .drafts, unreadByFolder: unread, draftCount: 0) == nil)
        #expect(ListColumn.menuCount(for: .inbox, unreadByFolder: [:], draftCount: 0) == nil)
    }

    /// The menu's numbers are the CURRENT scope's — narrowing to a domain
    /// narrows them. Fails if the menu reads an account-wide count.
    @Test("Folder menu counts follow the scope")
    func menuCountsFollowScope() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        try await harness.store.reconcileDrafts([
            harness.draft("d_sales", mailboxID: "mbSales"),
            harness.draft("d_none", mailboxID: nil),
        ], accountID: ScopeHarness.account)
        await harness.model.start()
        await harness.settle()
        // Every fixture message is unread: sales, team, ops in the Inbox.
        #expect(harness.model.folderMenuCount(for: .inbox) == 3)
        #expect(harness.model.folderMenuCount(for: .drafts) == 2)

        harness.model.selectScope(harness.acmeScope)
        await harness.settle()
        #expect(harness.model.folderMenuCount(for: .inbox) == 2)
        #expect(harness.model.folderMenuCount(for: .drafts) == 1, "the unassigned draft is All domains only")
        #expect(harness.model.folderMenuCount(for: .conversation(.archived)) == nil)
    }

    // MARK: - Empty states

    /// Fails if the per-mailbox Drafts state loses its explanation or its way
    /// out, or if it leaks into a domain's Drafts (which has no such rule).
    @Test("Empty Drafts inside a mailbox explains itself and offers Show All Drafts")
    func draftsEmptyState() {
        let inMailbox = ListColumn.emptyState(
            folder: .drafts, scope: .mailbox("mbTeam"), scopeName: "team@acme.co",
            labelName: nil, searching: false, serverSearchPending: false
        )
        #expect(inMailbox.title == "No drafts in team@")
        #expect(inMailbox.message == "Drafts that aren’t tied to a mailbox are listed under All domains › Drafts.")
        #expect(inMailbox.offersShowAllDrafts)
        #expect(inMailbox.symbol == "doc.text")

        let inDomain = ListColumn.emptyState(
            folder: .drafts, scope: .domain("dom_acme"), scopeName: "acme.co",
            labelName: nil, searching: false, serverSearchPending: false
        )
        #expect(inDomain.title == "Nothing in Drafts")
        #expect(inDomain.message == "in acme.co")
        #expect(inDomain.offersShowAllDrafts == false)
    }

    @Test("Other empty folders say Nothing in {Folder} and the scope; a label says so")
    func folderEmptyStates() {
        let sent = ListColumn.emptyState(
            folder: .conversation(.sent), scope: .allDomains, scopeName: "All domains",
            labelName: nil, searching: false, serverSearchPending: false
        )
        #expect(sent.title == "Nothing in Sent")
        #expect(sent.message == "in All domains")
        #expect(sent.symbol == "paperplane")

        let labelled = ListColumn.emptyState(
            folder: .inbox, scope: .domain("dom_acme"), scopeName: "acme.co",
            labelName: "Client", searching: false, serverSearchPending: false
        )
        #expect(labelled.title == "Nothing in Inbox")
        #expect(labelled.message == "No conversations labelled Client here.")
    }

    /// A search that matched nothing is "No Results", and only suggests Return
    /// while the server has not been asked. Drafts filter locally only, so they
    /// say "No Results" too but never suggest Return.
    @Test("A search with no matches says No Results")
    func searchEmptyState() {
        let pending = ListColumn.emptyState(
            folder: .inbox, scope: .allDomains, scopeName: "All domains",
            labelName: nil, searching: true, serverSearchPending: true
        )
        #expect(pending.title == "No Results")
        #expect(pending.message == "Press Return to search the server.")
        let asked = ListColumn.emptyState(
            folder: .inbox, scope: .allDomains, scopeName: "All domains",
            labelName: nil, searching: true, serverSearchPending: false
        )
        #expect(asked.message == nil)
        let drafts = ListColumn.emptyState(
            folder: .drafts, scope: .mailbox("mbTeam"), scopeName: "team@acme.co",
            labelName: nil, searching: true, serverSearchPending: true
        )
        #expect(drafts.title == "No Results")
        #expect(drafts.message == nil, "Return does nothing more in Drafts")
    }

    // MARK: - Window title

    /// Fails if the title stops following the scope — e.g. stays the account
    /// name inside a domain, or names a mailbox by anything but its address.
    @Test("The window title is the account, the domain, or the mailbox address")
    func windowTitleFollowsScope() {
        #expect(ListColumn.windowTitle(.allDomains, accountLabel: "Alan", scopeName: "All domains") == "Alan")
        #expect(ListColumn.windowTitle(.domain("d"), accountLabel: "Alan", scopeName: "shabubox.com") == "shabubox.com")
        #expect(
            ListColumn.windowTitle(.mailbox("m"), accountLabel: "Alan", scopeName: "hello@shabubox.com")
                == "hello@shabubox.com"
        )
    }

    /// The live bridge: the view-model's title moves with the sidebar scope.
    @Test("The view-model's window title follows the sidebar scope")
    func windowTitleBridge() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()
        let model = harness.model
        #expect(model.windowTitle == model.accountLabel)
        model.selectScope(harness.acmeScope)
        await harness.settle()
        #expect(model.windowTitle == "acme.co")
        model.selectScope(.mailbox("mbSales"))
        await harness.settle()
        #expect(model.windowTitle == "sales@acme.co")
    }

    // MARK: - Drafts search

    static func draft(_ id: String, subject: String, to: [String], snippet: String) -> DraftSummary {
        DraftSummary(
            id: id, mailboxID: nil, recipients: to, subject: subject, snippet: snippet,
            updatedAt: epoch, hasAttachments: false
        )
    }

    static let sampleDrafts = [
        draft("1", subject: "Quarterly Report", to: ["bob@acme.co"], snippet: "numbers attached"),
        draft("2", subject: "Lunch", to: ["Carol@North.io"], snippet: "see you at noon"),
        draft("3", subject: "Hello", to: [], snippet: "The REPORT is late"),
    ]

    /// Fails if a field is left out of the match, if matching is
    /// case-sensitive, or if a whitespace-only needle filters anything.
    @Test("Drafts search matches subject, recipients and snippet, ignoring case")
    func draftsFilter() {
        let ids = { (q: String) in ListColumn.filterDrafts(Self.sampleDrafts, query: q).map(\.id) }
        #expect(ids("report") == ["1", "3"], "subject and snippet, any case")
        #expect(ids("carol@north") == ["2"], "recipients, any case")
        #expect(ids("  lunch ") == ["2"], "the needle is trimmed")
        #expect(ids("zzz").isEmpty)
        #expect(ids("") == ["1", "2", "3"])
        #expect(ids("   ") == ["1", "2", "3"], "whitespace is no filter")
    }

    /// Show All Drafts returns to All domains KEEPING Drafts (not the Inbox),
    /// and the listing then includes the mailbox-less drafts.
    @Test("Show All Drafts widens to All domains and stays in Drafts")
    func showAllDrafts() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        try await harness.store.reconcileDrafts([
            harness.draft("d_none", mailboxID: nil),
        ], accountID: ScopeHarness.account)
        await harness.model.start()
        harness.model.selectScope(.mailbox("mbTeam"))
        harness.model.selectFolder(.drafts)
        await harness.settle()
        #expect(harness.model.drafts.isEmpty)
        #expect(harness.model.listEmptyState.offersShowAllDrafts)

        harness.model.showAllDrafts()
        await harness.settle()
        #expect(harness.model.scope == .allDomains)
        #expect(harness.model.folder == .drafts)
        #expect(harness.model.drafts.map(\.id) == ["d_none"])
    }

    // MARK: - Density

    /// Fails if the density table is mis-transcribed (padding 14 / 7, snippet
    /// 2 / 1 lines, subject on its own line vs inline).
    @Test("Comfortable and Compact carry the handoff's metrics")
    func densityMetrics() {
        let comfortable = ListColumn.RowMetrics(.comfortable)
        #expect(comfortable.verticalPadding == 14)
        #expect(comfortable.snippetLines == 2)
        #expect(comfortable.subjectInline == false)
        let compact = ListColumn.RowMetrics(.compact)
        #expect(compact.verticalPadding == 7)
        #expect(compact.snippetLines == 1)
        #expect(compact.subjectInline)
    }

    /// The row-height floor is the list's unmeasured-row height, so it must
    /// be a FULL row of the density: fails if Compact keeps Comfortable's floor
    /// (compact rows would be padded back up) or if a line is left out.
    @Test("Row-height floors add up the lines each density draws")
    func rowHeights() {
        let lines = ListColumn.LineHeights(body: 18, caption: 14, snippetLine: 15, snippetLineSpacing: 2)
        // 2×14 + line 1 (18) + 3 + subject 18 + 3 + snippet (15+2+15)
        #expect(ListColumn.RowMetrics(.comfortable).conversationRowHeight(lines) == 102)
        // 2×7 + line 1 (18, subject inline) + 3 + snippet 15
        #expect(ListColumn.RowMetrics(.compact).conversationRowHeight(lines) == 50)
        // Line 1 is never shorter than the 16pt domain badge.
        let small = ListColumn.LineHeights(body: 12, caption: 10, snippetLine: 11, snippetLineSpacing: 0)
        let smallCompact = ListColumn.RowMetrics(.compact).conversationRowHeight(small)
        #expect(smallCompact == 44)
        // Message rows: 2×pad + sender 18 + 2 + To: 14 + 2 + snippet.
        let comfortableMessage = ListColumn.RowMetrics(.comfortable).messageRowHeight(lines)
        #expect(comfortableMessage == 96)
        let compactMessage = ListColumn.RowMetrics(.compact).messageRowHeight(lines)
        #expect(compactMessage == 65)
    }

    @Test("An absent or unknown stored density is Comfortable")
    func densityResolves() {
        #expect(ListDensity.resolve(nil) == .comfortable)
        #expect(ListDensity.resolve("roomy") == .comfortable)
        #expect(ListDensity.resolve("compact") == .compact)
    }

    // MARK: - Thread

    static func message(
        _ id: String, from: String, direction: MessageDirection = .inbound
    ) -> MessageSummary {
        MessageSummary(
            id: id, threadID: "t", mailboxID: "mbSales", direction: direction, folder: .inbox,
            fromAddress: from, to: ["sales@acme.co"], subject: "S", snippet: "", receivedAt: epoch,
            sentAt: nil, readAt: nil, starredAt: nil, hasAttachments: false, createdAt: epoch
        )
    }

    /// People are distinct SENDERS by bare address, case-insensitively —
    /// fails if a display-name variant or a case change counts twice, or if
    /// recipients are counted too.
    @Test("N messages · M people counts distinct senders")
    func threadSummary() {
        let messages = [
            Self.message("1", from: "Jonas Weber <jonas@fieldnotes.press>"),
            Self.message("2", from: "jonas@FIELDNOTES.press"),
            Self.message("3", from: "Lena Brandt <lena@fieldnotes.press>"),
            Self.message("4", from: "Ari <ari@wizemann.studio>", direction: .outbound),
            Self.message("5", from: "\"Jonas Weber\" <Jonas@fieldnotes.press>"),
        ]
        #expect(ListColumn.participantCount(messages) == 3)
        #expect(ListColumn.threadSummary(messages) == "5 messages · 3 people")
        #expect(ListColumn.threadSummary([Self.message("1", from: "a@b.c")]) == "1 message · 1 person")
    }

    /// Own = outbound, or from any of the account's mailbox addresses (the
    /// bare address, whatever the display name or case). Fails if only the
    /// direction is checked (a copy delivered to another of the user's
    /// mailboxes would get a neutral avatar) or if the display name defeats it.
    @Test("Own messages: outbound, or from an address the account owns")
    func ownMessageDetection() {
        let own: Set<String> = ["sales@acme.co", "ops@north.io"]
        #expect(ListColumn.isOwnMessage(Self.message("1", from: "x@y.z", direction: .outbound), ownAddresses: own))
        #expect(ListColumn.isOwnMessage(Self.message("2", from: "Sales Team <SALES@acme.co>"), ownAddresses: own))
        #expect(ListColumn.isOwnMessage(Self.message("3", from: "ops@north.io"), ownAddresses: own))
        #expect(ListColumn.isOwnMessage(Self.message("4", from: "Mara <mara@client.com>"), ownAddresses: own) == false)
    }

    @Test("Sender names and initials come from the From header")
    func senderNameAndInitials() {
        #expect(ListColumn.senderName("\"Jonas Weber\" <jonas@x.io>") == "Jonas Weber")
        #expect(ListColumn.senderName("<jonas@x.io>") == "jonas@x.io")
        #expect(ListColumn.senderName("jonas@x.io") == "jonas@x.io")
        #expect(ListColumn.initials("Jonas Weber <jonas@x.io>") == "JW")
        #expect(ListColumn.initials("Mara Anne Okafor <m@x.io>") == "MA")
        #expect(ListColumn.initials("ops@north.io") == "OP")
        #expect(ListColumn.initials("Cher <c@x.io>") == "CH")
    }

    /// The account's own addresses as the thread rows compare them.
    @Test("The view-model's own-address keys are the lowercased mailbox addresses")
    func ownAddressKeys() async throws {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        await harness.model.start()
        #expect(harness.model.ownAddressKeys.isSuperset(of: ["sales@acme.co", "team@acme.co", "ops@north.io"]))
    }
}
