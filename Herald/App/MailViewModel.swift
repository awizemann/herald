import Foundation
import HeraldKit
import OSLog

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "MailViewModel")

/// The sync loop, as the view-model needs it. `nonisolated` so ``SyncEngine``
/// (an actor) can conform.
nonisolated protocol MailSyncing: Sendable {
    func refreshNow() async
    /// A pass that also re-reads `GET /drafts`, whatever the drafts interval says.
    func refreshDraftsNow() async
    /// A pass that also re-sweeps label membership, whatever the label interval says.
    func refreshLabelsNow() async
    func setCadence(_ cadence: SyncCadence) async
    /// Whether anything on screen is showing labels, which decides whether the
    /// membership sweep runs on its fast or its idle interval.
    func setLabelSurfaceVisible(_ visible: Bool) async
    /// Fetches one more SERVER page for the listings the sync pass stopped
    /// short on (its page cap). `true` while more may remain.
    func loadOlderConversations(mailboxIDs: Set<String>?, folder: ConversationFolder) async throws -> Bool
}

extension MailSyncing {
    /// Fakes that never cap a listing have nothing older to fetch.
    func loadOlderConversations(mailboxIDs: Set<String>?, folder: ConversationFolder) async throws -> Bool { false }
}

extension SyncEngine: MailSyncing {}

/// The wake socket, as the view-model needs it: something it can bring up while
/// the app is frontmost and take down when it is not. `nonisolated` so
/// ``MailEventSocket`` (an actor) can conform.
nonisolated protocol MailWaking: Sendable {
    func start() async
    func stop() async
}

extension MailEventSocket: MailWaking {}

/// A request to open the composer. P0.5 owns the composer itself; this is the
/// hook it plugs into, so ⌘R already has somewhere to land.
nonisolated struct ComposeRequest: Sendable, Hashable, Identifiable {
    enum Kind: Sendable, Hashable {
        case reply, replyAll, forward, new
        /// Reopen an existing server draft, identified by ``ComposeRequest/draftID``.
        case draft
    }

    let id = UUID()
    var kind: Kind
    var messageID: String?
    var mailboxID: String?
    /// Set only for `.draft`.
    var draftID: String?
}

/// The body of one message, prepared for ``MessageWebView``.
nonisolated struct RenderedBody: Sendable, Equatable {
    var messageID: String
    /// Fully substituted HTML — inline `cid:` parts are already data: URLs.
    var html: String
    /// Whether the remote-blocking rule list is applied to this render.
    var blocksRemote: Bool
    /// Whether the "Load remote images" banner should be offered.
    var offersRemoteConsent: Bool
    /// Whether the blocked images live only in the collapsed quoted history, so
    /// the banner can say which part of the message it is about.
    var remoteConsentIsForQuotedHistoryOnly: Bool = false
}

/// The single owner of UI state.
///
/// Everything the views read lives here as Sendable DTOs; no `@Model` and no
/// generated API type ever reaches a view. Reads come from ``MailStore``; the
/// network is only touched for what the cache cannot hold (HTML bodies, inline
/// images, attachment data) and for the write half of an action.
@MainActor
@Observable
final class MailViewModel {
    enum SyncStatus: Equatable {
        case idle
        case syncing
        case failed(String)
        case needsReauth
    }

    // Scope, Folder and Location live in `MailNavigation.swift`.

    // MARK: Dependencies

    let accountID: String
    let accountLabel: String
    let api: any MailAPIClient
    /// Internal, like ``api`` and ``actions``, so the view-model's own extension
    /// files can read it. Still view-model-only: it hands back Sendable DTOs and
    /// no view ever holds a reference to it.
    let store: MailStore
    let actions: MailActionService
    /// Internal for the same reason as ``store``: the drafts extension drives it.
    let sync: (any MailSyncing)?
    /// The wake socket, when this account has one. Assigned after `init` rather
    /// than injected, because the socket's callbacks point back AT this
    /// view-model: it cannot exist before the thing it talks to. `nil` in tests
    /// that are not about it, and on any account whose graph came up without one.
    @ObservationIgnored var wake: (any MailWaking)?
    private let events: AsyncStream<SyncEvent>
    /// How long a message must stay selected before it is marked read. Injected
    /// so tests can drive both sides of the rule without real waiting.
    private let markReadDelay: Duration
    /// Where the alert switches, the account tint override, the navigation
    /// state and the domain preferences live. Injected so a test drives a
    /// throwaway suite instead of the user's real preferences. Internal, like ``store``/``actions``, so a
    /// view can resolve a Herald-only preference (the reading pane's domain
    /// badge reads `DomainPreferences`/`AccountTintAssignment` through it)
    /// without this type growing new stored state — see ``DomainBadgeResolver``.
    let defaults: UserDefaults
    /// Whether ``location`` is restored from and written to ``defaults``
    /// (``NavigationPersistence``). On for the real app and the UI-test
    /// harness; off by default so the many view-model tests that share
    /// `UserDefaults.standard` and an account id cannot restore each other's
    /// navigation.
    private let persistsNavigation: Bool
    /// Posts new-mail banners for this account. `nil` in tests that are not about
    /// notifications, and in any build where the user turned them off.
    private let notifier: NewMailNotifier?
    /// Classifies new mail (Workflows). `nil` in tests that are not about it.
    /// Internal so the account graph can stop it on teardown.
    let classification: ClassificationEngine?
    /// Where the AI Gateway token is checked for, per pass that has rules on.
    private let classificationSecrets: any SecretStore
    /// Set when classification paused on a gateway-level failure (rejected
    /// token, no credits, model not enabled, bot block) — the Workflows page
    /// shows it. Raised once per pause, never per message.
    var classificationPause: AIGatewayError?
    /// Called with ``badgeInboxUnread`` whenever the counts are recomputed — the
    /// Dock badge's only input. A closure rather than an observation loop
    /// so the badge updates exactly when the count does. Observation-ignored: no
    /// view reads it, and assigning it would otherwise invalidate every observer.
    @ObservationIgnored var unreadCountDidChange: (@MainActor (Int) -> Void)?
    /// Called with this account's id the moment Herald decides only a fresh
    /// sign-in can fix things (see ``reportSessionExpired()``) — on the
    /// TRANSITION into ``SyncStatus/needsReauth``
    /// and not on the failed passes that follow it, so one expired session is one
    /// request no matter how many polls fail behind it. ``AppEnvironment`` decides
    /// whether to act on it; the banner is up either way.
    @ObservationIgnored var reauthenticationRequired: (@MainActor (Account.ID) -> Void)?
    /// Where usage events go. A closure rather than the tracker itself: the
    /// view-model must not be able to reach `flush`/`setEnabled`, and
    /// ``AppEnvironment`` owns the ordering chain behind this. Default no-op, so
    /// every test that does not care about analytics records nothing.
    @ObservationIgnored let record: @MainActor @Sendable (UsageEvent) -> Void

    /// What the NEXT view change was reached by. Set by the caller immediately
    /// before it navigates (a sidebar click, a search result, a notification, a
    /// shortcut) and consumed by the very next attempt to change the view —
    /// whether or not that attempt actually changes anything, so a no-op click
    /// cannot leave a stale label behind for the next real navigation to wear.
    @ObservationIgnored var pendingNavigationSource: UsageViewTrigger?

    /// Takes the pending source, leaving `.other` behind for anything that
    /// navigates without saying how.
    private func consumeNavigationSource() -> UsageViewTrigger {
        defer { pendingNavigationSource = nil }
        return pendingNavigationSource ?? .other
    }

    /// The event vocabulary's name for a conversation folder.
    nonisolated static func viewKind(for folder: ConversationFolder) -> UsageViewKind {
        switch folder {
        case .inbox: .inbox
        case .sent: .sent
        case .starred: .starred
        case .archived: .archived
        case .trash: .trash
        case .catchall: .catchall
        }
    }

    /// The event vocabulary's name for a scope — its kind, never its id.
    nonisolated static func scopeKind(for scope: Scope) -> UsageScopeKind {
        switch scope {
        case .allDomains: .allDomains
        case .domain: .domain
        case .mailbox: .mailbox
        }
    }

    /// The event vocabulary's name for a list folder.
    nonisolated static func viewKind(for folder: Folder) -> UsageViewKind {
        switch folder {
        case .conversation(let folder): viewKind(for: folder)
        case .drafts: .drafts
        }
    }

    /// The view the middle column is showing right now.
    private var currentViewKind: UsageViewKind {
        if isShowingThread { return .thread }
        return Self.viewKind(for: location.folder)
    }

    /// Records one `view_shown`. Internal so the extensions can call it.
    func recordViewShown(_ view: UsageViewKind, via: UsageViewTrigger) {
        record(.viewShown(view: view, via: via))
    }

    // MARK: Published state

    /// The mailboxes Herald shows: every cached mailbox the owner has NOT
    /// switched off at the server (``Mailbox/isEnabled``). Everything
    /// domain-shaped — the sidebar, counts, badge, notifications, Settings'
    /// domain pages, the From address — is derived from this list, so
    /// filtering it once in ``reloadMailboxes()`` is what removes a disabled
    /// mailbox (or a whole disabled domain) everywhere.
    private(set) var mailboxes: [Mailbox] = []
    /// The cached mailboxes ``mailboxes`` leaves out. The store still holds
    /// their mail (sync is untouched), so every "every mailbox" fast path must
    /// check this is empty before taking it.
    private var disabledMailboxes: [Mailbox] = []
    /// Every cached mailbox, disabled ones included — for monogram assignment
    /// ONLY (``monogramDomains``, the reading pane's badge). Nothing listed,
    /// counted or sent from reads this.
    var monogramMailboxes: [Mailbox] { mailboxes + disabledMailboxes }
    /// The domains of ``monogramMailboxes``. Monogram clashes are resolved over
    /// these, so a domain the server disables never changes the letters
    /// another domain shows — the same promise hiding a domain keeps.
    private(set) var monogramDomains: [MailDomain] = []
    /// The account's domains, derived from ``mailboxes`` on every mailbox
    /// reload (``MailDomain/domains(from:)``) — a domain scope is the set of
    /// its mailboxes' ids, and nothing about it lives on the server.
    private(set) var domains: [MailDomain] = []
    /// mailbox id → the name a row should attribute a message to. Built once per
    /// mailbox reload: the "All Mailboxes" list draws this on EVERY row, and a
    /// `mailboxes.first(where:)` per row is a linear scan per row per render.
    private(set) var mailboxNames: [String: String] = [:]
    /// Unread conversations per sidebar folder, for the CURRENT scope — the
    /// folder rows' badges.
    private(set) var folderUnreadCounts: [ConversationFolder: Int] = [:]

    // The sidebar's domain / mailbox / All domains counts are ALWAYS Inbox
    // unread, whatever folder the list shows (plan v2 decision N6: a Sent
    // unread count means nothing). Only ids with unread appear in the maps.

    /// Inbox unread per mailbox — the mailbox rows' counts.
    private(set) var inboxUnreadByMailbox: [Mailbox.ID: Int] = [:]
    /// Inbox unread per domain: DISTINCT threads over its mailboxes, not the
    /// sum of their counts — a thread with messages in two of a domain's
    /// mailboxes has a row under each, and summing counted it twice
    /// (``UnreadTally``).
    private(set) var inboxUnreadByDomain: [MailDomain.ID: Int] = [:]
    /// Inbox unread of the "All domains" scope — hidden and not-included
    /// domains left out, counted over the SAME mailbox set the All domains
    /// listing reads (``mailboxIDs(for:)``), so the row's number is what
    /// opening it shows. The account card's and the account list's count.
    private(set) var allDomainsInboxUnread = 0
    /// This account's share of the Dock badge: Inbox unread over every domain
    /// that is neither hidden nor switched out of "Count unread in the Dock
    /// badge" (``badgeMailboxIDs()``). Independent of "All domains": a domain
    /// kept out of the combined list can still count toward the badge.
    private(set) var badgeInboxUnread = 0

    // MARK: Reload generation
    //
    // Every async reload (the list, the label index, the counts, the drafts)
    // captures ``reloadGeneration`` before its first store read and publishes
    // only if it is unchanged. It is bumped by whatever changes what those
    // reads MEAN — a navigation, a per-domain preference write, a change to
    // the mailbox/domain list — and every bumper starts the reloads its
    // change needs, so a dropped answer is always superseded by a newer one.
    // Checking `location` alone missed the last two: a count read begun
    // before "exclude from All domains" landed after it with the old number.

    /// See above. Internal so the drafts and labels extensions can check it.
    @ObservationIgnored private(set) var reloadGeneration = 0

    /// Test seam: runs after a count reload's store read, just before its
    /// generation check — the one moment a navigation can land between a
    /// count being computed and published. `nil` outside tests.
    @ObservationIgnored var countsWillPublish: (@MainActor () -> Void)?

    /// Whether the list is waiting on the store after a move to a different
    /// scope or folder. The rows are cleared at once rather than left under
    /// the new header (they answered the OLD location's question); a same
    /// location reload keeps its rows until the new ones land, so a sync tick
    /// never flickers the list.
    private(set) var isLoadingConversations = false

    /// Bumped by ``domainPreferencesDidChange()``. `DomainPreferences` live in
    /// `UserDefaults`, which Observation cannot see; everything the
    /// view-model derives from them reads through ``observedDefaults`` so a
    /// monogram override or an exclusion repaints what was drawn from it.
    private(set) var domainPreferencesRevision = 0

    /// ``defaults``, read in a way Observation records — pass THIS (never
    /// `defaults`) wherever a view draws from `DomainPreferences` through the
    /// view-model.
    var observedDefaults: UserDefaults {
        _ = domainPreferencesRevision
        return defaults
    }

    /// Bumped on every mailbox reload; with ``domainPreferencesRevision`` it
    /// keys ``resolvedSetsCache``.
    @ObservationIgnored private var mailboxListRevision = 0

    /// The mailbox sets All domains, the Dock badge and the notification
    /// filter resolve to. Each read preferences for every domain and built a
    /// fresh `Set`, and ``mailboxIDs(for:)`` is asked once per changed message
    /// in a sync pass — so they are resolved once per (mailbox list,
    /// preferences) and reused.
    private struct ResolvedSets {
        let mailboxListRevision: Int
        let preferencesRevision: Int
        let allDomains: Set<String>?
        let badge: Set<String>?
        let silenced: Set<String>
    }

    @ObservationIgnored private var resolvedSetsCache: ResolvedSets?

    private var resolvedSets: ResolvedSets {
        let preferences = domainPreferencesRevision
        if let cached = resolvedSetsCache,
           cached.mailboxListRevision == mailboxListRevision,
           cached.preferencesRevision == preferences {
            return cached
        }
        let resolved = ResolvedSets(
            mailboxListRevision: mailboxListRevision,
            preferencesRevision: preferences,
            allDomains: resolveMailboxIDs(excluding: isExcludedFromAllDomains),
            badge: resolveMailboxIDs(excluding: isExcludedFromBadge),
            silenced: resolveSilencedMailboxIDs()
        )
        resolvedSetsCache = resolved
        return resolved
    }

    // MARK: Navigation
    //
    // Three independent axes — scope, folder, label — held as ONE value and
    // changed only through ``navigate(to:reportsView:)`` and the intent methods
    // built on it, so each axis's side effects (the `view_shown`, leaving a
    // drilled-in thread, cancelling the server search, the reload, persisting)
    // happen in one place whichever axis moved.

    /// Where the middle column is looking. See ``Location``.
    private(set) var location: Location = .launchDefault

    /// Which mail the list is drawn from.
    var scope: Scope { location.scope }
    /// Which folder the list shows.
    var folder: Folder { location.folder }
    /// The open label, or `nil`. It narrows the folder listing (label ∩ folder
    /// ∩ scope); it no longer spans folders on its own.
    var selectedLabelID: String? { location.labelID }
    /// Whether the middle column is showing the Drafts list instead of
    /// conversations.
    var isShowingDrafts: Bool { location.folder == .drafts }

    /// THE navigation step. Every intent method lands here.
    ///
    /// - Parameter reportsView: `false` for a correction nobody asked for (a
    ///   stale scope falling back once the mailbox list arrives): it records no
    ///   `view_shown` and leaves the pending navigation source for whatever the
    ///   user does next.
    func navigate(to target: Location, reportsView: Bool = true) {
        // Consumed BEFORE the no-op guard: re-picking what is already showing
        // is a navigation that happened, and leaving its `via` behind would
        // mislabel whatever the user does next.
        let via = reportsView ? consumeNavigationSource() : nil
        let old = location
        guard target != old else { return }
        location = target
        reloadGeneration &+= 1
        persistLocation()
        // A new listing starts from its first page again.
        conversationListLimit = Self.conversationPageSize
        cacheMayHaveMoreConversations = false
        serverMayHaveMoreConversations = true
        isLoadingMoreConversations = false
        // A label-only change is deliberately NOT reported: the usage
        // vocabulary (`UsageViewKind`) has no label view, and inventing one
        // means a new wire name and a new fixture id — an analytics change that
        // belongs with the rest of the vocabulary. Its source is still consumed
        // above, so a click cannot leave a stale `via` behind.
        if let via, target.scope != old.scope {
            // Before the view it produces, so a funnel reads "moved, then saw".
            record(.scopeChanged(to: Self.scopeKind(for: target.scope), via: via))
        }
        if let via, target.scope != old.scope || target.folder != old.folder {
            recordViewShown(Self.viewKind(for: target.folder), via: via)
        }
        // The rows under the selection are about to be replaced; nil-ing it is
        // also what drops a drilled-in thread (its `didSet` turns the pane off
        // without reporting anything — whatever caused this reported its view).
        selectedThreadID = nil
        leaveThreadSilently()
        let entersDrafts = target.folder == .drafts && old.folder != .drafts
        if entersDrafts { selectedDraftID = nil }
        // Server search answers a (scope, folder) question; its rows answer the
        // OLD location's question and would leak into the new list.
        cancelServerSearch()
        // Another scope or folder is a different listing: the rows on screen
        // answer the old one, and leaving them under the new header until the
        // store answers showed (say) one domain's inbox titled as another's.
        // A label change only narrows the same listing, so it keeps them.
        if target.scope != old.scope || target.folder != old.folder {
            isLoadingConversations = true
            if !allConversations.isEmpty { allConversations = [] }
        }
        // The folder and the label are the presentation rule, so the visible
        // list is wrong until it is recomputed — don't wait for the store.
        refilter()
        // Cancel first: replacing a running task leaves the older, slower
        // reload alive to finish last and overwrite the newer location's rows.
        reloadTask?.cancel()
        let opensLabel = target.labelID != nil && target.labelID != old.labelID
        let labelChanged = target.labelID != old.labelID
        reloadTask = Task { [weak self] in
            await self?.reloadConversations()
            // Entering a listing turns the fast sweep cadence on; leaving one
            // may turn it off again (only may — the sidebar's badges keep it on
            // while the app is frontmost).
            if labelChanged { await self?.updateLabelSurfaceVisibility() }
            // Same reason opening Drafts asks for a drafts poll: the
            // reconciliation runs on a slow interval precisely because nobody is
            // usually looking, and it is the only thing that brings in
            // assignments for folders this cache never listed.
            if opensLabel { await self?.sync?.refreshLabelsNow() }
        }
        // Drafts are scoped too, so a scope change re-reads them (and their
        // badge) even when the Drafts list is not on screen. A drafts read
        // still in flight is re-run as well: the generation bump above drops
        // its answer, and nothing else would replace it.
        if entersDrafts || target.scope != old.scope || draftReloadsInFlight > 0 {
            // Owned, and cancelled by `stop()`: an unstructured `Task` here
            // outlives the account graph that spawned it.
            draftTask?.cancel()
            draftTask = Task { [weak self] in
                await self?.reloadDrafts()
                // Entering asks the engine for a fresh drafts list: the drafts
                // poll runs on its own slow interval precisely because nobody
                // is usually looking, and this is the moment somebody is.
                if entersDrafts { await self?.sync?.refreshDraftsNow() }
            }
        }
    }

    // MARK: Navigation intents
    //
    // What the sidebar, the menus and a notification click ask for. Views call
    // these rather than composing a ``Location`` themselves, so the redesign's
    // rules live here once: the folder survives a scope change, the label
    // survives both and narrows with the scope, and only an explicit clear or
    // the "All domains" row drops it.

    /// Moves the scope, keeping the folder and the open label.
    func selectScope(_ scope: Scope) {
        var target = location
        target.scope = scope
        navigate(to: target)
    }

    /// The sidebar's "All domains" row: the widest scope, and it closes an open
    /// label (the design's second way to clear one, beside the chip's ×).
    func selectAllDomains() {
        var target = location
        target.scope = .allDomains
        target.labelID = nil
        navigate(to: target)
    }

    /// Moves the folder, keeping the scope — and the label unless asked not to.
    /// - Parameter clearingLabel: for a control that picks a folder INSTEAD of
    ///   a label (today's sidebar, which has one selection for both); dropped in
    ///   the same step, so it is one navigation and one `view_shown`.
    func selectFolder(_ folder: Folder, clearingLabel: Bool = false) {
        var target = location
        target.folder = folder
        if clearingLabel { target.labelID = nil }
        navigate(to: target)
    }

    /// A label row was clicked: opens the label, or closes it when it is the
    /// one already open. Keeps scope and folder — except Drafts, which carry no
    /// label Herald can read, so opening one from there lands on the Inbox.
    func openLabel(_ labelID: String) {
        var target = location
        if target.folder == .drafts {
            // Kept open behind Drafts it narrows nothing on screen, so clicking
            // it is asking to SEE it, never to close it.
            target.folder = .inbox
            target.labelID = labelID
        } else {
            target.labelID = target.labelID == labelID ? nil : labelID
        }
        navigate(to: target)
    }

    /// The label chip's ×, and the fallback when the open label no longer exists.
    func clearLabel() {
        var target = location
        target.labelID = nil
        navigate(to: target)
    }

    // MARK: Scope resolution

    /// The mailbox ids a scope lists, or `nil` for "every mailbox" — the ONE
    /// place a ``Scope`` becomes the set every store query takes.
    ///
    /// `.allDomains` leaves out the domains the user hid or took out of "All
    /// domains", and every mailbox the server disabled; when there is none of
    /// either, the answer is `nil` rather than the full set, so the store keeps
    /// its unfiltered fast path. An explicit All domains set always holds
    /// ``unassignedMailboxKey``: mail tied to NO mailbox belongs to no domain,
    /// so no domain's exclusion can take it out — the same rule the drafts
    /// list keeps with `includingUnassigned`. A domain that no longer exists
    /// resolves to the EMPTY set (lists nothing) rather than to everything.
    func mailboxIDs(for scope: Scope) -> Set<String>? {
        switch scope {
        case .mailbox(let id):
            return [id]
        case .domain(let id):
            return Set(domains.first { $0.id == id }?.mailboxIDs ?? [])
        case .allDomains:
            return resolvedSets.allDomains
        }
    }

    /// The `mailboxKey` of a conversation row tied to no mailbox (an
    /// unassigned catch-all message) — `mailboxID ?? ""` in the store.
    nonisolated static let unassignedMailboxKey = ""

    /// Every enabled mailbox minus the domains `isExcluded` rejects, plus the
    /// unassigned key — or `nil` ("every mailbox") when nothing is excluded
    /// and nothing disabled.
    private func resolveMailboxIDs(excluding isExcluded: (MailDomain) -> Bool) -> Set<String>? {
        let excluded = domains.filter(isExcluded)
        guard !excluded.isEmpty || !disabledMailboxes.isEmpty else { return nil }
        var ids = Set(mailboxes.map(\.id)).subtracting(excluded.flatMap(\.mailboxIDs))
        ids.insert(Self.unassignedMailboxKey)
        return ids
    }

    /// Whether a domain stays out of the `.allDomains` listing on this Mac.
    func isExcludedFromAllDomains(_ domain: MailDomain) -> Bool {
        let defaults = observedDefaults
        return DomainPreferences.isHidden(accountID: accountID, domainID: domain.id, in: defaults)
            || !DomainPreferences.includeInAll(accountID: accountID, domainID: domain.id, in: defaults)
    }

    /// Whether a domain's unread stays out of the Dock badge on this Mac.
    func isExcludedFromBadge(_ domain: MailDomain) -> Bool {
        let defaults = observedDefaults
        return DomainPreferences.isHidden(accountID: accountID, domainID: domain.id, in: defaults)
            || !DomainPreferences.countInBadge(accountID: accountID, domainID: domain.id, in: defaults)
    }

    /// The mailboxes whose Inbox unread counts toward the Dock badge, or `nil`
    /// for "every mailbox" — the same shape, fast path and unassigned rule as
    /// the `.allDomains` case of ``mailboxIDs(for:)``, with `countInBadge` in
    /// place of `includeInAll`.
    func badgeMailboxIDs() -> Set<String>? {
        resolvedSets.badge
    }

    /// Mailboxes whose new mail must not post a banner: every mailbox the
    /// server has disabled, every mailbox of a hidden domain, and of a domain
    /// whose own "Notify me about new mail" is explicitly off.
    ///
    /// Only ever NARROWS the global switch. `notify == nil` follows the global
    /// setting, and an explicit `true` cannot override a global OFF: the global
    /// switch is the master (``notifyNewMail(_:)`` returns before this is
    /// asked). Otherwise a domain toggled off and back on — which stores an
    /// explicit `true` — would keep posting after the user silenced Herald.
    func notificationSilencedMailboxIDs() -> Set<String> {
        resolvedSets.silenced
    }

    private func resolveSilencedMailboxIDs() -> Set<String> {
        let defaults = observedDefaults
        var silenced = Set(disabledMailboxes.map(\.id))
        for domain in domains {
            let hidden = DomainPreferences.isHidden(accountID: accountID, domainID: domain.id, in: defaults)
            let notify = DomainPreferences.notify(accountID: accountID, domainID: domain.id, in: defaults)
            if hidden || notify == false { silenced.formUnion(domain.mailboxIDs) }
        }
        return silenced
    }

    /// Re-reads everything a per-domain preference feeds — the All domains
    /// listing and its drafts, every unread count, the Dock badge, the
    /// notification filter and every monogram drawn through
    /// ``observedDefaults``. Reached through
    /// `AppEnvironment.updateDomainPreferences`, the one call a
    /// Settings/sidebar control makes after writing `DomainPreferences`
    /// (monogram, include in All domains, count in badge, notify,
    /// hide/restore) — and the ONLY thing that invalidates the cached
    /// resolved sets, so a preference written any other way is not seen. What
    /// happens to a scope standing IN a domain that was just hidden is the
    /// Hide flow's call (R9), not this reload's.
    ///
    /// `reloads: false` is for a write that only changes how things are DRAWN
    /// (a monogram override): the revision still moves — every monogram and
    /// cached set re-reads — but the list, drafts and counts are not refetched.
    func domainPreferencesDidChange(reloads: Bool = true) async {
        domainPreferencesRevision &+= 1
        guard reloads else { return }
        // Any read already in flight resolved its mailbox set before the write.
        reloadGeneration &+= 1
        await reloadConversations()
        await reloadDrafts()
    }

    /// Whether a message's mailbox is inside a resolved scope set. A message
    /// with no mailbox matches by ``unassignedMailboxKey``, like its row.
    nonisolated static func mailboxIDs(_ ids: Set<String>?, contain mailboxID: String?) -> Bool {
        guard let ids else { return true }
        return ids.contains(mailboxID ?? unassignedMailboxKey)
    }

    /// `location` with any part that no longer exists replaced — the scope by
    /// All domains, the label by none.
    ///
    /// The scope is only judged once mailboxes are loaded: on a cold cache the
    /// list is empty until the first sync, and dropping a perfectly good scope
    /// then would lose it for good. The label IS judged against an empty list,
    /// the same rule ``reloadLabels()`` applies: a workspace whose last label was
    /// deleted must not keep an invisible filter on the list.
    func validatedLocation(_ location: Location) -> Location {
        var result = location
        if !mailboxes.isEmpty || !disabledMailboxes.isEmpty {
            switch location.scope {
            case .allDomains:
                break
            case .domain(let id):
                if !domains.contains(where: { $0.id == id }) { result.scope = .allDomains }
            case .mailbox(let id):
                if !mailboxes.contains(where: { $0.id == id }) { result.scope = .allDomains }
            }
        }
        if let labelID = location.labelID, !labels.contains(where: { $0.id == labelID }) {
            result.labelID = nil
        }
        return result
    }

    private func persistLocation() {
        guard persistsNavigation else { return }
        NavigationPersistence.save(location, accountID: accountID, to: defaults)
    }

    // MARK: Drafts
    //
    // Storage only. Every write to these lives in `MailViewModel+Drafts.swift`,
    // which owns the drafts behaviour; they are plain `var`s rather than
    // `private(set)` because `private` in Swift does not reach an extension in
    // another file, and the alternative was to inline the whole feature here.

    /// The drafts list for the current scope, newest edit first. Sendable DTOs
    /// — the list never sees a `@Model` and never holds a draft body.
    var drafts: [DraftSummary] = []
    /// The Drafts badge for the current scope. Counted in the store
    /// (`fetchCount`), never by loading rows.
    var draftCount = 0
    var selectedDraftID: String? {
        didSet { if oldValue != selectedDraftID { loadSelectedDraftPreview() } }
    }
    /// What the reading pane shows for the selected draft (see
    /// `MailViewModel+Drafts.swift`). A Sendable value resolved from the cache —
    /// `nil` while nothing is selected or the draft is gone.
    var selectedDraftPreview: DraftPreview?
    /// The in-flight preview resolution, owned so a newer selection (and
    /// ``stop()``) can cancel it.
    @ObservationIgnored var draftPreviewTask: Task<Void, Never>?

    /// Instrumentation, same contract as the conversation counter: it exists so
    /// "the drafts list reloaded exactly once" is assertable.
    @ObservationIgnored var draftReloadCount = 0
    /// The in-flight drafts load, owned so ``stop()`` can cancel it.
    @ObservationIgnored var draftTask: Task<Void, Never>?
    /// How many ``reloadDrafts()`` calls are between their capture and their
    /// publish — what tells a navigation that bumps the generation that a
    /// drafts answer is about to be dropped and needs re-running.
    @ObservationIgnored var draftReloadsInFlight = 0

    // MARK: Labels
    //
    // Storage only, same arrangement as the drafts block above: every write lives
    // in `MailViewModel+Labels.swift`.

    /// The workspace's labels, name-ordered. Shared across mailboxes — a label is
    /// not scoped to one, and assigning it never moves a message.
    var labels: [MailLabel] = []
    /// thread id → the label ids on ANY of its messages, so a row's chips are a
    /// dictionary lookup rather than a store round trip per row.
    ///
    /// A `Set`, not an array: every read of it is a membership test (the chips,
    /// the context menu's checkmark), and an array made each one a linear scan
    /// inside a view body.
    var labelIDsByThread: [String: Set<String>] = [:]
    /// label id → how many cached conversations in the current folder and
    /// scope carry it (``labelCountLocation``), precomputed alongside the
    /// index. The sidebar draws one badge per label per render pass, and
    /// deriving each by walking the index was O(threads × labels) IN THE VIEW
    /// BODY — the audit's P2.
    var labelThreadCounts: [String: Int] = [:]
    /// The label ids on the message the reading pane is showing.
    var selectedMessageLabelIDs: [String] = []
    /// Whether the app is frontmost, as ``setActive(_:)`` last saw it. Kept
    /// because the label surface signal needs it and the cadence it drives is
    /// write-only from here.
    @ObservationIgnored var isAppActive = true
    /// What the sync engine was last told about the label surface, so a signal
    /// recomputed from four places is only sent when it actually flips.
    @ObservationIgnored var isLabelSurfaceVisible = false
    /// Instrumentation, same contract as ``conversationReloadCount``: it exists
    /// so "one label write rebuilt the index exactly once" is assertable. Not
    /// `private(set)` only because the write lives in the labels extension file.
    @ObservationIgnored var labelIndexReloadCount = 0

    // MARK: Paging
    //
    // The list shows the newest ``conversationPageSize`` threads and grows by
    // that much each time the user scrolls to its end (``loadMoreConversations()``).
    // Every reload — a sync tick included — re-reads the CURRENT limit, so a
    // background pass can never truncate what the user already paged in, and
    // rows come from one store query, so a page boundary cannot duplicate one.
    // Past the cache, the sync engine fetches further server pages for any
    // listing its pass stopped short on (its page cap).

    static let conversationPageSize = 100
    /// How many threads the current listing reads from the store.
    private(set) var conversationListLimit = MailViewModel.conversationPageSize
    /// Whether the last read filled its limit — the store may hold more.
    private(set) var cacheMayHaveMoreConversations = false
    /// Cleared once the engine says the server has nothing older for this
    /// listing; reset by every navigation.
    private(set) var serverMayHaveMoreConversations = true
    private(set) var isLoadingMoreConversations = false
    /// The load-more row's identity. Bumped only by a load that made progress —
    /// it added visible rows, or it found the cache exhausted so the next load
    /// asks the server — so a row still on screen fires again only then. A load
    /// that added nothing visible (a local search filtering every new row out, a
    /// server page of rows this listing does not show) leaves the row as it is:
    /// the next load waits for the user to scroll it away and back, instead of
    /// chaining cache reads or server fetches on its own.
    private(set) var loadMoreTrigger = 0
    /// Whether the list should end in a "load more" row.
    var canLoadMoreConversations: Bool {
        guard location.folder.conversationFolder != nil else { return false }
        return cacheMayHaveMoreConversations || (location.labelID == nil && serverMayHaveMoreConversations)
    }

    /// Everything the store holds for the current scope, before search.
    private(set) var allConversations: [ConversationSummary] = [] {
        didSet {
            searchIndex = Self.makeSearchIndex(allConversations)
            refilter()
        }
    }

    /// Committed search text (the field debounces before pushing here). It only
    /// narrows the presented list — never the loaded slice, so the reading pane
    /// does not re-render on a keystroke.
    var searchQuery: String = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            // A new needle invalidates the previous server pass completely: its
            // rows matched a different string. Cancel BEFORE refiltering so the
            // list never shows the old query's server hits under the new one.
            cancelServerSearch()
            refilter()
            clearHiddenDraftSelection()
            // NOT reported here: this fires on every debounced keystroke, so
            // "typed one word" would arrive as five searches. A search is what
            // the user COMMITTED — see ``submitSearch()``.
            autoRunServerSearchIfSparse()
        }
    }

    /// Rows the list shows: the scope's conversations minus anything a local
    /// action moved out of it, narrowed by the committed search text.
    ///
    /// STORED, not computed. As a computed property it re-filtered — and
    /// re-lowercased every subject, sender and snippet — on every read, and the
    /// list's body reads it on every unrelated `@Observable` change, so a sync
    /// status flip or an `actionError` cost a full re-filter of the scope.
    ///
    /// Selection is always resolved against ``allConversations``, never this, so
    /// typing in the search field cannot tear down the reading pane.
    private(set) var presentedConversations: [ConversationSummary] = []

    /// Thread id → the lowercased header text search matches against, built once
    /// per load instead of once per row per keystroke.
    @ObservationIgnored private var searchIndex: [String: String] = [:]

    /// MESSAGE id → the lowercased, truncated body text of a row's latest
    /// message, for the rows whose body the cache already holds.
    ///
    /// Keyed by message id (not thread id) because that is what the body sidecar
    /// is keyed by, and loaded separately from ``searchIndex`` because it costs a
    /// store round trip — the header index must be ready synchronously, the
    /// moment the rows land.
    @ObservationIgnored private var bodySearchIndex: [String: String] = [:]

    /// The id set a body-index pass is currently loading, or `nil` when none is
    /// in flight. Guards against restarting an identical pass on every sync tick.
    @ObservationIgnored private var loadingBodyIndexIDs: Set<String>?

    /// Set when a re-index was asked for while a pass over the SAME ids was still
    /// in flight — i.e. the rows are unchanged but a body behind one of them was
    /// just cached. Consumed by that pass as it finishes.
    @ObservationIgnored private var bodyIndexNeedsRerun = false

    /// What the SERVER half of search is doing. The local half is always
    /// instant; this is the only part with a state worth showing.
    enum ServerSearchState: Equatable {
        case idle
        case searching
        /// How many threads the server matched (before dedupe against the cache).
        case completed(Int)
        /// User-facing reason; the list still shows its local results.
        case failed(String)
    }

    private(set) var serverSearchState: ServerSearchState = .idle

    /// Rows the server matched that the local pass did not. NOT observed and NOT
    /// written to the cache — see ``runServerSearch()`` for why. Every writer
    /// calls ``refilter()`` itself.
    @ObservationIgnored private var serverResults: [ConversationSummary] = []

    /// Instrumentation: how many server searches were actually dispatched, so
    /// "a keystroke did NOT hit the network" is assertable.
    @ObservationIgnored private(set) var serverSearchCount = 0

    /// Instrumentation: how many times the presented list has actually been
    /// recomputed. Observation-ignored — it exists so "an unrelated change did
    /// NOT re-filter" is assertable at all.
    @ObservationIgnored private(set) var filterCount = 0

    var selectedThreadID: String? {
        didSet {
            guard selectedThreadID != oldValue else { return }
            threadTask?.cancel()
            let threadID = selectedThreadID
            threadMessages = []
            selectedMessageID = nil
            // Owner decision 2026-08-16: SELECTING a multi-message conversation
            // drills straight into its message list (⎋ / back returns); a
            // single-message conversation just previews in the reading pane.
            // `isMultiMessage` reads the presented rows, which are already loaded.
            // ONLY a user-driven selection drills: a programmatic advance past a
            // deleted row (see `select(_:drill:)`) must land on the next thread
            // without opening it (issue #5).
            let drills = drillsOnSelection ? (threadID.map(isMultiMessage) ?? false) : false
            // Only the way IN is an event. Dropping out of a thread because the
            // selection moved (or the folder changed) is not a navigation of its
            // own: whatever caused it already reported the view it landed on.
            let entersThread = drills && !isShowingThread
            isShowingThread = drills
            if entersThread { recordViewShown(.thread, via: consumeNavigationSource()) }
            guard let threadID else { return }
            threadTask = Task { await loadThread(threadID) }
        }
    }

    /// Whether the CURRENT write to ``selectedThreadID`` counts as a user
    /// selection. Only `select(_:drill:)` ever turns it off, and only for the
    /// duration of one synchronous assignment.
    @ObservationIgnored private var drillsOnSelection = true

    /// Assigns the selection, optionally without drilling into a multi-message
    /// thread. The `didSet` runs synchronously, so the flag is back up before
    /// this returns and no other write can see it down.
    func select(_ threadID: String?, drill: Bool) {
        drillsOnSelection = drill
        defer { drillsOnSelection = true }
        selectedThreadID = threadID
    }

    /// Whether the middle column is showing the selected thread's messages
    /// instead of the conversation list.
    ///
    /// Turned on whenever the selection lands on a multi-message conversation
    /// (owner decision 2026-08-16), and by ``openSelectedThread()`` for the
    /// re-click / ⏎ / chevron cases where the selection did not change.
    ///
    /// VM state, deliberately NOT a `NavigationStack` push: a push rebuilds the
    /// column (and would need an `.id()`-shaped reset to come back to the same
    /// scroll position), where a flag lets both lists stay lazy and keeps the
    /// selection exactly where it was.
    private(set) var isShowingThread = false

    private(set) var threadMessages: [MessageSummary] = []

    var selectedMessageID: String? {
        didSet {
            guard selectedMessageID != oldValue else { return }
            detailTask?.cancel()
            markReadTask?.cancel()
            detail = nil
            body = nil
            // The superseded load no longer owns the flag (see `loadDetail`), so
            // the selection change is what clears it.
            isLoadingBody = false
            guard let messageID = selectedMessageID else { return }
            detailTask = Task { await loadDetail(messageID) }
            markReadTask = Task { await markReadAfterDwell(messageID) }
            // The chips come from the CACHE, so they are there the moment the
            // selection lands rather than after the detail round trip.
            labelTask?.cancel()
            labelTask = Task { await reloadSelectedMessageLabels() }
        }
    }

    private(set) var detail: MessageDetail?
    private(set) var body: RenderedBody?
    private(set) var isLoadingBody = false
    /// How many inline parts of the presented message could not be rendered
    /// (fetch failed, or the part was not renderable media). Surfaced as a note
    /// under the body rather than left as a hole the reader cannot explain.
    private(set) var inlineImagesUnavailable = 0
    private(set) var status: SyncStatus = .idle
    /// When the last pass finished cleanly. The sidebar's status slot is always
    /// present, so idle needs something quiet to say.
    private(set) var lastSyncedAt: Date?
    /// Last user-visible action error; the UI clears it by setting nil.
    var actionError: String?
    /// P0.5 reads this; ⌘R writes it.
    var composeRequest: ComposeRequest?

    /// Instrumentation: how many times each slice has actually been reloaded.
    /// Observation-ignored because it is a counter for tests, not UI state — but
    /// it is what makes "did NOT reload speculatively" assertable at all.
    @ObservationIgnored private(set) var conversationReloadCount = 0
    @ObservationIgnored private(set) var threadReloadCount = 0

    // MARK: Tasks

    /// Exposed so tests can assert the superseded reload was cancelled, not just
    /// dropped on the floor. Not `private(set)`: the labels extension owns the
    /// label listing's reload and lives in another file, where `private` does not
    /// reach.
    @ObservationIgnored var reloadTask: Task<Void, Never>?
    private var threadTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    /// The reading pane's label load. Owned so `stop()` can cancel it.
    @ObservationIgnored var labelTask: Task<Void, Never>?
    /// A running domain "Mark All as Read" (`SidebarNavigation.swift`). Owned
    /// so `stop()` — sign-out, account teardown — cancels it instead of
    /// leaving it POSTing for an account that is gone.
    @ObservationIgnored var markAllTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    /// Exposed so tests can await the dwell timer instead of sleeping.
    private(set) var markReadTask: Task<Void, Never>?

    init(
        accountID: String,
        accountLabel: String,
        api: any MailAPIClient,
        store: MailStore,
        actions: MailActionService,
        sync: (any MailSyncing)? = nil,
        events: AsyncStream<SyncEvent>,
        markReadDelay: Duration = .seconds(1),
        defaults: UserDefaults = .standard,
        persistsNavigation: Bool = false,
        notifier: NewMailNotifier? = nil,
        classification: ClassificationEngine? = nil,
        classificationSecrets: any SecretStore = KeychainStore(),
        record: @escaping @MainActor @Sendable (UsageEvent) -> Void = { _ in }
    ) {
        self.record = record
        self.defaults = defaults
        self.persistsNavigation = persistsNavigation
        self.notifier = notifier
        self.classification = classification
        self.classificationSecrets = classificationSecrets
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.api = api
        self.store = store
        self.actions = actions
        self.sync = sync
        self.events = events
        self.markReadDelay = markReadDelay
    }

    /// Stops consuming sync events. Called when the account is torn down —
    /// `deinit` cannot do it, being nonisolated.
    func stop() {
        eventTask?.cancel()
        reloadTask?.cancel()
        draftPreviewTask?.cancel()
        threadTask?.cancel()
        detailTask?.cancel()
        markReadTask?.cancel()
        bodyIndexTask?.cancel()
        cancelServerSearch()
        draftTask?.cancel()
        labelTask?.cancel()
        markAllTask?.cancel()
    }

    // MARK: - Derived state

    /// Recomputes ``presentedConversations``. The ONLY writer of it, called from
    /// the `didSet` of each of the three inputs the filter depends on.
    /// Internal, not private: the labels extension recomputes it after a label
    /// write moves the index a server row is filtered by.
    func refilter() {
        filterCount += 1
        // Drafts are not conversations: that list is `drafts`, and nothing here
        // is on screen while it is.
        guard let folder = location.folder.conversationFolder else {
            presentedConversations = []
            return
        }
        // A label listing is a FOLDER listing narrowed by the label, so the same
        // folder rule applies: a row a local archive just moved out of the inbox
        // leaves the Inbox ∩ label list too.
        let inScope = allConversations.filter { Self.belongs($0, to: folder) }
        // Trimmed, and trimmed HERE as well as on the wire: the local tier and
        // the server tier must agree on what the needle is, or a trailing space
        // silently empties the list while the server still finds rows.
        let needle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            presentedConversations = inScope
            return
        }
        var rows = inScope.filter { matchesLocally($0, needle) }
        // Union with whatever the server matched that the cache does not hold.
        // Local rows win on identity: they carry any optimistic action the user
        // just took, where the server's copy predates it.
        if !serverResults.isEmpty {
            let labelID = location.labelID
            var seen = Set(rows.map(\.id))
            for row in serverResults where Self.belongs(row, to: folder) && seen.insert(row.id).inserted {
                // Server search cannot filter by label, so inside a label only
                // the rows the label index says carry it are hits — a row that
                // does not would read as one that does. The index holds
                // assignments for uncached messages too (the reconciliation
                // stores them), which is what makes this more than a guess.
                if let labelID, labelIDsByThread[row.id]?.contains(labelID) != true { continue }
                rows.append(row)
            }
            rows.sort { $0.latest.displayDate > $1.latest.displayDate }
        }
        presentedConversations = rows
    }

    /// Whether a cached row matches the needle: headers first (always indexed),
    /// then the body of its latest message if the cache happens to hold one.
    private func matchesLocally(_ row: ConversationSummary, _ needle: String) -> Bool {
        if searchIndex[row.id]?.contains(needle) == true { return true }
        return bodySearchIndex[row.latest.id]?.contains(needle) == true
    }

    /// The searchable header text of each row, lowercased once at load time.
    ///
    /// Recipients are in it as well as sender and subject: "who did I send this
    /// to" is half of what search is for, and `to` is already on the row DTO. `cc`
    /// is not — it only exists on ``MessageDetail`` — so a cc-only match is left
    /// to the server tier.
    private nonisolated static func makeSearchIndex(
        _ rows: [ConversationSummary]
    ) -> [String: String] {
        var index: [String: String] = [:]
        index.reserveCapacity(rows.count)
        for row in rows {
            let recipients = row.latest.to.joined(separator: " ")
            index[row.id] = """
                \(row.latest.subject)
                \(row.latest.fromAddress)
                \(recipients)
                \(row.latest.snippet)
                """
                .lowercased()
        }
        return index
    }

    // MARK: - Search: the body half of the local index

    /// How much of one cached body is indexed. The index is resident for every
    /// row on screen, so an unbounded one is a mailbox's worth of newsletter HTML
    /// held in memory to answer a substring test.
    static let bodySearchPrefixLength = 4096

    /// Loads cached body text for the rows now on screen.
    ///
    /// Deliberately NOT part of `allConversations.didSet`: it is a store round
    /// trip, and the header index — which is what the first keystroke filters on
    /// — must be ready synchronously. Nothing is FETCHED for search; only bodies
    /// the reading pane already cached participate.
    private func refreshBodySearchIndex() {
        let ids = allConversations.map(\.latest.id)
        guard !ids.isEmpty else {
            bodyIndexTask?.cancel()
            loadingBodyIndexIDs = nil
            bodyIndexNeedsRerun = false
            guard !bodySearchIndex.isEmpty else { return }
            bodySearchIndex = [:]
            // The rows that matched on body text are gone with the index.
            if !searchQuery.isEmpty { refilter() }
            return
        }
        let wanted = Set(ids)
        // A sync burst calls this on every ChangeSet. Restarting a pass that is
        // already loading EXACTLY these ids means each store round trip is
        // cancelled before it lands and the body index never populates at all —
        // body search would silently degrade to headers-only, with no signal.
        //
        // But the SAME rows can have different bodies behind them: the reading
        // pane caches a body as a side effect of opening a message, and that
        // write lands mid-pass. Dropping the request outright made that body
        // unsearchable until the row set itself changed. Coalesced into ONE
        // re-run after the in-flight pass lands instead — which restarts nothing
        // and still bounds a burst to a single extra pass.
        guard loadingBodyIndexIDs != wanted else {
            bodyIndexNeedsRerun = true
            return
        }
        bodyIndexTask?.cancel()
        loadingBodyIndexIDs = wanted
        // This pass reads the store fresh, so it already answers any request that
        // was coalesced onto the pass it supersedes.
        bodyIndexNeedsRerun = false
        let store = self.store
        let accountID = self.accountID
        bodyIndexTask = Task { [weak self] in
            let texts = (try? await store.cachedBodyTexts(
                messageIDs: ids, accountID: accountID, maxLength: Self.bodySearchPrefixLength
            )) ?? [:]
            guard !Task.isCancelled else { return self?.releaseBodyIndexPass(wanted) ?? () }
            // Lowercasing up to a hundred 4 KB bodies is real work and the main
            // actor is drawing the list it belongs to.
            let lowered = await Task.detached(priority: .utility) { @Sendable in
                texts.mapValues { $0.lowercased() }
            }.value
            guard let self else { return }
            // Released BEFORE the re-run check, or the coalesced request would be
            // deduped against the very pass that is finishing.
            self.releaseBodyIndexPass(wanted)
            guard !Task.isCancelled else { return }
            // The rows may have moved on while this was in flight; keeping only
            // the ids still on screen is what stops the index growing without
            // bound across folder switches.
            self.bodySearchIndex = lowered.filter { wanted.contains($0.key) }
            if !self.searchQuery.isEmpty { self.refilter() }
            guard self.bodyIndexNeedsRerun else { return }
            self.bodyIndexNeedsRerun = false
            self.refreshBodySearchIndex()
        }
    }

    /// Drops this pass's dedupe marker, if it still owns it.
    private func releaseBodyIndexPass(_ wanted: Set<String>) {
        guard loadingBodyIndexIDs == wanted else { return }
        loadingBodyIndexIDs = nil
    }

    // MARK: - Search: the server tier

    /// Below this many local hits, the debounced query reaches for the server on
    /// its own — the case the two-tier design exists for is "the answer is older
    /// than the cache", and that looks exactly like an empty local result.
    static let serverSearchAutoThreshold = 3

    /// Shorter needles are a `LIKE %x%` full scan upstream that matches most of
    /// the mailbox; never worth a round trip, submitted or not.
    static let minimumServerSearchLength = 2

    /// Cap on pages walked per server search. The server pages at ~50, so this is
    /// 250 threads — past that the needle is too broad to be an answer.
    static let maxServerSearchPages = 5

    /// Exposed so tests can await (and assert the cancellation of) the pass.
    @ObservationIgnored private(set) var serverSearchTask: Task<Void, Never>?
    /// Exposed for the same reason as ``serverSearchTask``: the body index is
    /// loaded on an unstructured task, and a test that asserts on it without
    /// awaiting it is asserting on a race.
    @ObservationIgnored private(set) var bodyIndexTask: Task<Void, Never>?

    /// The Return key in the search field: search the server for what is on
    /// screen now, whether or not the local pass found anything.
    ///
    /// This is also where the LOCAL search is reported. The local tier has been
    /// re-running on every debounced keystroke since the first letter; the moment
    /// the user pressed Return is the one moment they asked a question, and only
    /// the RESULT COUNT is reported, bucketed — the needle itself never leaves.
    func submitSearch() {
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            record(.searchRun(
                scope: .local,
                results: UsageBucket(count: isShowingDrafts ? presentedDrafts.count : presentedConversations.count)
            ))
        }
        runServerSearch()
    }

    private func autoRunServerSearchIfSparse() {
        guard presentedConversations.count < Self.serverSearchAutoThreshold else { return }
        runServerSearch()
    }

    /// Runs `GET /conversations?search=` for the CURRENT scope, paging through
    /// with the cursor, and unions the answer into the presented list.
    ///
    /// The rows are held as DTOs rather than upserted into the cache. The cache's
    /// conversation table is the sync engine's: a listing scope is authoritative
    /// there (`deleteMissing` tombstones anything a listing omits), and a search
    /// result is a FILTERED view of the same scope — injecting it would make the
    /// next pass's "these rows are all that is in the inbox" claim fight with a
    /// row set that was never a listing. Presenting from DTOs keeps the union
    /// exactly as long as the query lives and costs nothing to undo.
    func runServerSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= Self.minimumServerSearchLength else { return }
        // Drafts have no server search route; that list only filters locally.
        guard location.folder.conversationFolder != nil else { return }
        let scope = location
        serverSearchTask?.cancel()
        serverSearchCount += 1
        serverSearchState = .searching
        serverSearchTask = Task { [weak self] in
            await self?.performServerSearch(query, scope: scope)
        }
    }

    /// Forgets one server-search row.
    ///
    /// A server result is a DTO snapshot with no cache row behind it, so nothing
    /// re-derives it: archiving or trashing such a row would otherwise see it
    /// re-unioned — still claiming its old folder — on the very next refilter,
    /// and the row would spring back as though the action had failed.
    func dropServerResult(_ threadID: String) {
        guard serverResults.contains(where: { $0.id == threadID }) else { return }
        serverResults.removeAll { $0.id == threadID }
        if case .completed = serverSearchState {
            serverSearchState = .completed(serverResults.count)
        }
        refilter()
    }

    /// Drops any in-flight server pass and its rows. Called whenever the question
    /// changes (new needle, new scope) and by ``stop()``.
    func cancelServerSearch() {
        serverSearchTask?.cancel()
        serverSearchTask = nil
        guard !serverResults.isEmpty || serverSearchState != .idle else { return }
        serverResults = []
        serverSearchState = .idle
    }

    /// The request for one scope. The API filters by at most ONE mailbox, so a
    /// mailbox scope is asked exactly and every wider scope asks for all
    /// mailboxes — its answer is then narrowed client-side to the scope's set
    /// (a domain's mailboxes; All domains minus the excluded ones).
    private func performServerSearch(_ query: String, scope: Location) async {
        guard let folder = scope.folder.conversationFolder else { return }
        let requestMailboxID: String? = if case .mailbox(let id) = scope.scope { id } else { nil }
        // Resolved once, up front: a wider scope's answer is filtered by the set
        // the question was asked about, not whatever the mailbox list says by
        // the time the last page lands.
        let allowed = requestMailboxID == nil ? mailboxIDs(for: scope.scope) : nil
        var collected: [ConversationSummary] = []
        var seen: Set<String> = []
        var cursor: String?
        var page = 0

        while page < Self.maxServerSearchPages {
            let result: ConversationPage
            do {
                result = try await api.listConversations(
                    folder: folder,
                    mailboxID: requestMailboxID,
                    search: query,
                    cursor: cursor
                )
            } catch {
                // A cancelled pass answers a question nobody is asking; its
                // failure is not a failure the user should be told about.
                guard !Task.isCancelled, !Self.isCancellation(error), isCurrentSearch(query, scope) else { return }
                logger.warning("Server search failed: \(error.localizedDescription, privacy: .private)")
                // Anything that is not a `MailAPIError` counts as `other`: the
                // search failed either way, and nothing of the error survives.
                record(.searchFailed(kind: UsageMailErrorKind(anyError: error)))
                serverResults = collected
                serverSearchState = .failed(Self.serverSearchMessage(for: error))
                refilter()
                return
            }
            // The needle or the folder moved while the page was in flight.
            guard !Task.isCancelled, isCurrentSearch(query, scope) else { return }
            for row in result.conversations
            where Self.mailboxIDs(allowed, contain: row.latest.mailboxID) && seen.insert(row.id).inserted {
                collected.append(row)
            }
            page += 1
            guard let next = result.nextCursor else { break }
            cursor = next
        }

        guard !Task.isCancelled, isCurrentSearch(query, scope) else { return }
        record(.searchRun(scope: .server, results: UsageBucket(count: collected.count)))
        serverResults = collected
        serverSearchState = .completed(collected.count)
        refilter()
    }

    /// Whether the pass that is finishing still answers what is on screen. The
    /// scope AND the needle both have to still hold: `searchQuery` is compared
    /// trimmed because that is the form the request was built from.
    private func isCurrentSearch(_ query: String, _ scope: Location) -> Bool {
        location == scope
            && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
    }

    /// URLSession reports a cancelled request as an error like any other, and the
    /// API layer wraps it into `.transport`; treating that as a real failure would
    /// flash "search failed" on every keystroke.
    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        guard let api = error as? MailAPIError, case .transport(let failure) = api else { return false }
        return failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled
    }

    /// What the status line says when a server pass fails. Offline is called out
    /// by name: it is the one failure where "you are seeing local results only"
    /// is the whole explanation and retrying is pointless.
    nonisolated static func serverSearchMessage(for error: any Error) -> String {
        if let api = error as? MailAPIError, case .transport = api {
            return "Offline — showing local results only"
        }
        return (error as? any LocalizedError)?.errorDescription ?? "Server search failed"
    }

    /// The status line under the list. `nil` when there is nothing to say.
    var serverSearchDescription: String? {
        guard !searchQuery.isEmpty else { return nil }
        switch serverSearchState {
        case .idle: return nil
        case .searching: return "Searching server…"
        case .completed(let count):
            return count == 1 ? "1 result from server" : "\(count) results from server"
        case .failed(let message): return message
        }
    }

    var selectedConversation: ConversationSummary? {
        guard let selectedThreadID else { return nil }
        return conversation(withID: selectedThreadID)
    }

    /// A presented row by thread id, from the cache FIRST and the server search
    /// second.
    ///
    /// Server-only rows have to be resolvable here or selecting one is a dead
    /// end: the thread header, the drill-in test and the reading-pane load all
    /// resolve the selection through this, and a cache-only lookup answers `nil`
    /// for exactly the rows the second tier exists to surface.
    func conversation(withID threadID: String) -> ConversationSummary? {
        allConversations.first { $0.id == threadID }
            ?? serverResults.first { $0.id == threadID }
    }

    var selectedMessage: MessageSummary? {
        guard let selectedMessageID else { return nil }
        return threadMessages.first { $0.id == selectedMessageID }
    }

    /// Whether a thread is worth drilling into. Resolved against
    /// ``allConversations`` (the unfiltered source), never the presented list: a
    /// search that hides the row must not change what selecting it does.
    private func isMultiMessage(_ threadID: String) -> Bool {
        (conversation(withID: threadID)?.messageCount ?? 1) > 1
    }

    /// The back chevron / ⎋ / ⌘[: leave the thread, keep the row selected.
    func exitThread() {
        guard isShowingThread else { return }
        isShowingThread = false
        // Back to whatever list was underneath.
        recordViewShown(currentViewKind, via: consumeNavigationSource())
    }

    /// ⌘[ and ⎋: the same back step, reached from the keyboard rather than by
    /// clicking the chevron. The source is cleared afterwards rather than left
    /// for the next navigation to wear, since ``exitThread()`` consumes nothing
    /// when there is no thread to leave.
    func exitThreadViaShortcut() {
        pendingNavigationSource = .shortcut
        exitThread()
        pendingNavigationSource = nil
    }

    /// ⏎ in the conversation list — the keyboard's way into a thread.
    func openSelectedThreadViaShortcut() {
        pendingNavigationSource = .shortcut
        openSelectedThread()
        pendingNavigationSource = nil
    }

    /// Leaves the thread pane WITHOUT reporting a view: for callers that are on
    /// their way somewhere else and will report that destination themselves
    /// (entering the Drafts folder).
    func leaveThreadSilently() {
        isShowingThread = false
    }

    /// Drills into the selected conversation — the ⏎ and chevron path. A
    /// single-message conversation has nothing to drill into and is a no-op:
    /// it is already fully shown in the reading pane.
    func openSelectedThread() {
        guard let selectedThreadID, isMultiMessage(selectedThreadID) else { return }
        guard !isShowingThread else { return }
        isShowingThread = true
        recordViewShown(.thread, via: consumeNavigationSource())
    }

    /// Drills into a specific row — the mouse-click path, where the click both
    /// selects and opens. Selecting first is deliberate: it is what loads the
    /// thread, and re-clicking the row that is already selected must still open
    /// it (the selection binding would report no change at all).
    func openThread(_ threadID: String) {
        // A row opened out of a filtered list was reached by searching, whatever
        // the mouse did to get there. An explicit source still wins.
        if pendingNavigationSource == nil, !searchQuery.isEmpty {
            pendingNavigationSource = .search
        }
        selectedThreadID = threadID
        openSelectedThread()
    }

    /// The name a row in the "All Mailboxes" scope is attributed to. A dictionary
    /// lookup, built at mailbox-reload time — the alternative is a linear scan of
    /// `mailboxes` per row per render.
    func mailboxName(for id: String?) -> String? {
        guard let id else { return nil }
        return mailboxNames[id]
    }

    // MARK: - Account tint

    /// Bumped by ``accountTintDidChange()`` — `AppEnvironment.setAccountTint`
    /// calls it — so every row, avatar and badge drawn from ``accountTint``
    /// repaints the moment Settings › Account changes the colour. The tint
    /// itself lives in `UserDefaults`, which Observation cannot see.
    private(set) var accountTintRevision = 0

    func accountTintDidChange() { accountTintRevision &+= 1 }

    /// The account's tint — the one hue a row's domain badge and the user's own
    /// thread avatar are drawn in, now that mailboxes have no colour of their own (handoff §2: "Account →
    /// colour… Nothing else gets its own hue"). The user's override
    /// (`account.<accountID>.tint`) wins, else the stable hash default.
    ///
    /// Read through on every call rather than cached: it is one `UserDefaults`
    /// lookup, and ``accountTintRevision`` is what makes it observable.
    var accountTint: MailTheme.AccountTint? {
        _ = accountTintRevision
        let override = defaults.string(forKey: AccountTintAssignment.storageKey(accountID: accountID))
        return MailTheme.accountTint(named: AccountTintAssignment.token(forAccountID: accountID, override: override))
    }

    /// What the sidebar's fixed-height status slot says. Pure and static: the
    /// slot must ALWAYS have text (an empty one is what made the sidebar jump),
    /// and that is only assertable off-screen if the text is a function.
    nonisolated static func statusDescription(
        for status: SyncStatus,
        lastSyncedAt: Date?
    ) -> String {
        switch status {
        case .syncing: "Syncing…"
        case .failed: "Sync problem"
        case .needsReauth: "Sign in again"
        // A wall-clock stamp, not a relative one: "0 seconds ago" would be wrong
        // within a second of being drawn and nothing re-renders it until the next
        // pass. Never empty — an empty slot is what made the sidebar reflow.
        case .idle:
            if let lastSyncedAt {
                "Updated \(lastSyncedAt.formatted(date: .omitted, time: .shortened))"
            } else {
                "Up to date"
            }
        }
    }

    /// A local archive/trash leaves the row in its old listing scope with a new
    /// message folder; the list must stop showing it immediately.
    nonisolated static func belongs(_ row: ConversationSummary, to folder: ConversationFolder) -> Bool {
        switch row.latest.folder {
        case .trash: folder == .trash
        case .archived: folder == .archived
        default: folder != .trash && folder != .archived
        }
    }

    // MARK: - Lifecycle

    /// Loads everything from the cache and starts consuming sync events.
    func start() async {
        eventTask?.cancel()
        eventTask = Task { [weak self] in await self?.consumeEvents() }
        await reloadMailboxes()
        // Before the restore, so a persisted label can be judged against them.
        await reloadLabels()
        restoreLocation()
        await reloadConversations()
        await reloadDrafts()
        // The restored label (if any) is a label surface the engine has not
        // been told about yet.
        await updateLabelSurfaceVisibility()
        // The launch view has to be said out loud: the restore above assigns
        // `location` directly, not through `navigate`, so nothing else reports
        // the folder the window comes up on. Once per view-model — a
        // re-`start()` (there is none today) must not double-count a launch.
        guard !didRecordLaunchView else { return }
        didRecordLaunchView = true
        pendingNavigationSource = nil
        recordViewShown(currentViewKind, via: .launch)
    }

    @ObservationIgnored private var didRecordLaunchView = false

    /// Puts back the location this account was last showing, once, at launch.
    ///
    /// Assigned DIRECTLY, not through ``navigate(to:reportsView:)``: nothing is
    /// loaded yet (``start()`` loads right after), and the launch view is
    /// reported by ``start()`` exactly once, whatever was restored. The restore
    /// used to live in the sidebar and race `start()` for the right to report
    /// the launch view; owning it here removes the race by construction.
    ///
    /// A scope whose domain or mailbox is gone, or a label that is, falls back
    /// (``validatedLocation(_:)``). A scope that cannot be judged yet — a cold
    /// cache with no mailboxes — is kept, and corrected silently by
    /// ``correctStaleScope()`` once the mailbox list arrives.
    private func restoreLocation() {
        guard persistsNavigation, !didRestoreLocation else { return }
        didRestoreLocation = true
        let stored = NavigationPersistence.load(accountID: accountID, from: defaults)
        location = validatedLocation(stored)
        if location != stored { persistLocation() }
    }

    @ObservationIgnored private var didRestoreLocation = false

    /// Falls back to All domains when the scope's domain or mailbox stopped
    /// existing (access revoked, a restore that ran before the first sync).
    /// Silent: nobody navigated, and the view on screen was already reported.
    private func correctStaleScope() {
        var target = validatedLocation(location)
        // The label is ``reloadLabels()``'s to judge, against the label list —
        // this runs on a MAILBOX reload, whatever the labels are doing.
        target.labelID = location.labelID
        guard target != location else { return }
        navigate(to: target, reportsView: false)
    }

    /// Set by ``refresh()``, consumed by the next `.finished` event.
    @ObservationIgnored private var reloadsWhenPassFinishes = false

    // MARK: Sync trigger attribution
    //
    // ``SyncEvent`` carries no trigger, so it is derived here: the FIRST pass a
    // view-model sees is the launch pass, an explicit ``refresh()`` claims the
    // next completion as manual, and everything else is the cadence.

    /// Claimed by ``refresh(trigger:)``, consumed by the next terminal event.
    @ObservationIgnored private var requestedSyncTrigger: UsageSyncTrigger?
    @ObservationIgnored private var hasReportedSyncPass = false
    /// Whether anything actually changed during the pass now in flight.
    @ObservationIgnored private var passChangedAnything = false

    private func consumeSyncTrigger() -> UsageSyncTrigger {
        defer {
            requestedSyncTrigger = nil
            hasReportedSyncPass = true
        }
        if let requestedSyncTrigger { return requestedSyncTrigger }
        return hasReportedSyncPass ? .auto : .launch
    }

    /// The Refresh button (and ⌘⇧K, and the post-action refresh).
    ///
    /// A pass only reports what CHANGED, and a pass that changed nothing the
    /// current scope's rows are keyed by used to leave the list exactly as it
    /// was — which is what made "Refresh doesn't show the mail I just deleted,
    /// but leaving the folder and coming back does" (issue #6). Whatever the
    /// ChangeSets say, an explicit refresh reloads the presented scope once the
    /// pass finishes, because that is what pressing Refresh means.
    /// - Parameter trigger: how this pass is reported. The button, ⌘⇧K and the
    ///   pull-to-refresh path are `manual`; the reload that follows an action is
    ///   Herald's own doing and must not inflate the manual count.
    func refresh(trigger: UsageSyncTrigger = .manual) async {
        reloadsWhenPassFinishes = true
        if trigger == .manual { requestedSyncTrigger = .manual }
        await sync?.refreshNow()
    }

    func setActive(_ active: Bool) async {
        isAppActive = active
        await sync?.setCadence(active ? .active : .idle)
        // Same argument as the cadence, one surface further in: a backgrounded
        // Herald is drawing no chips and no badges, so the label sweep's 120s is
        // being spent on an answer nobody can see.
        await updateLabelSurfaceVisibility()
        // The wake socket follows the app's activation, exactly like the cadence
        // — and for a blunter reason: a socket held open behind a closed lid is a
        // radio kept awake for mail nobody is looking at. A backgrounded Herald
        // falls back to the 60s idle poll, which is what it did before the socket
        // existed, so nothing is lost by dropping it.
        if active {
            await wake?.start()
        } else {
            await wake?.stop()
        }
    }

    // MARK: - Session expiry

    /// The ONE transition into ``SyncStatus/needsReauth``: this account's session
    /// is dead and only a fresh sign-in can fix it.
    ///
    /// Every discoverer of a dead session lands here — a failed sync pass, the
    /// wake socket that could not authenticate, and the token provider's
    /// dead-session hook (routed by ``AppEnvironment``), which is how a failed
    /// send, draft autosave, message open, auto mark-read or signature read
    /// raises the banner at once instead of on the next poll. They discover the
    /// same death within moments of each other, so only the TRANSITION announces
    /// (``reauthenticationRequired``): one expiry, one automatic attempt, however
    /// many reporters. Idempotent while the banner is up.
    func reportSessionExpired() {
        let isNewExpiry = status != .needsReauth
        status = .needsReauth
        if isNewExpiry { reauthenticationRequired?(accountID) }
    }

    // MARK: - Wake socket

    /// Handles one frame from `GET /events`.
    ///
    /// Every case is a REFRESH, never a write: the frames carry no mail data and
    /// no cursor, so the only correct response to one is to go and read the
    /// authoritative REST resource. The mapping is not one-to-one with the
    /// topics, because the server's topics are not:
    ///
    /// - `messages` — the change journal (a normal pass). Label MEMBERSHIP
    ///   changes arrive here too (verified live: assigning a label to a message
    ///   publishes `messages`, not `labels`), and against a 1.4.2 server that is
    ///   now ENOUGH: the journal upsert the pass reads carries the message's
    ///   labels, so a plain refresh fixes the chips. It deliberately does NOT
    ///   force the per-label reconciliation — doing so would put one request per
    ///   label behind every read and every star in the workspace, which is what
    ///   this frame is. Against an older server the frame identifies nothing and
    ///   the reconciliation's own interval remains the only cure.
    /// - `mailboxes` — grants changed. A pass re-lists mailboxes anyway, so this
    ///   is the same refresh.
    /// - `drafts` — a whole-list drafts read, out of turn.
    /// - `labels` — the workspace label LIST (create/rename/delete). Forces the
    ///   reconciliation, because a DELETED label touches no message and so is
    ///   announced by nothing else: no row will ever mention it again.
    /// - `reconnected` — a gap in the socket is a gap in the frames, and nothing
    ///   is replayed across it, so every surface is re-read at once.
    func handleWakeSignal(_ signal: MailEventSignal) async {
        switch signal {
        case .changed(.messages), .changed(.mailboxes):
            await sync?.refreshNow()
        case .changed(.drafts):
            await sync?.refreshDraftsNow()
        case .changed(.labels):
            await sync?.refreshLabelsNow()
        case .reconnected:
            // Both forcing calls, then one pass covers all three surfaces.
            await sync?.refreshDraftsNow()
            await sync?.refreshLabelsNow()
            await sync?.refreshNow()
        }
    }

    // MARK: - Sync events

    private func consumeEvents() async {
        for await event in events {
            switch event {
            case .began:
                if status != .needsReauth { status = .syncing }
                passChangedAnything = false
            case .finished:
                record(.syncCompleted(trigger: consumeSyncTrigger(), changed: passChangedAnything))
                passChangedAnything = false
                if status != .needsReauth {
                    status = .idle
                    lastSyncedAt = .now
                }
                if reloadsWhenPassFinishes {
                    reloadsWhenPassFinishes = false
                    // Reloads the presented scope AND the unread badges.
                    await reloadConversations()
                }
            case .changed(let changes):
                if !changes.isEmpty { passChangedAnything = true }
                // A mailbox the same pass switched off must be silenced
                // before its mail is announced.
                if await touchesMailbox(changes) { await reloadMailboxes() }
                // Before the reloads: the banner is about what ARRIVED, and the
                // reload path can take several store round trips.
                await notifyNewMail(changes)
                // Only decides and queues; the model calls run off this loop.
                await classifyNewMail(changes)
                await apply(changes)
            case .draftsChanged(let changes):
                if !changes.isEmpty { passChangedAnything = true }
                await applyDraftChanges(changes)
            case .labelsChanged:
                passChangedAnything = true
                await applyLabelsChanged()
            case .failed(let error):
                // A `MailAPIError` reports its case; anything else (an OAuth
                // failure surfacing as the re-auth banner) reports `other`, so a
                // pass that failed is never invisible. No made-up kind, and
                // nothing of the error itself.
                let trigger = consumeSyncTrigger()
                passChangedAnything = false
                record(.syncFailed(kind: UsageMailErrorKind(anyError: error), trigger: trigger))
                if Self.requiresReauthentication(error) {
                    // The transition is the event: every poll while the session
                    // is dead fails the same way, and re-announcing it would ask
                    // for a new authorization window per cadence tick.
                    reportSessionExpired()
                } else if status != .needsReauth {
                    status = .failed(error.localizedDescription)
                }
                // Otherwise `.needsReauth` stays, like it does across `.began`
                // and `.finished`: a transport blip says nothing about the
                // session, and replacing the sign-in banner with "Sync problem /
                // Retry" hid the only way back in until the next pass against
                // the latched grant re-raised it (and re-announced it, into the
                // automatic attempt's cooldown). It clears only when a sign-in
                // installs a fresh graph for the account.
            }
        }
    }

    /// Every failure that only a fresh sign-in can fix must land on the re-auth
    /// banner, whose button re-runs consent — not on "Sync problem / Retry", where
    /// Retry just repeats the doomed refresh (issue #1: "not granted offline
    /// access" after ~1 h, Retry did nothing). Covers a rejected token, a refresh
    /// the server refused, and a missing refresh token, however deeply the API
    /// layer wrapped it — including the compose and signature services' own
    /// `.api(_:)` wrappers, so a composer can tell "sign in again" from "retry".
    ///
    /// Classification only: it raises nothing. The banner itself is raised by
    /// the token provider's hook the moment the death is discovered.
    nonisolated static func requiresReauthentication(_ error: any Error) -> Bool {
        if let api = error as? MailAPIError { return api == .unauthorized }
        if case .api(let api)? = error as? OutboxError { return api == .unauthorized }
        if case .api(let api)? = error as? SignatureManagementError { return api == .unauthorized }
        if let oauth = error as? OAuthError {
            switch oauth {
            case .reauthenticationRequired, .missingRefreshToken: return true
            default: return false
            }
        }
        return false
    }

    /// Hands the pass to the notifier, unless the user switched banners off.
    ///
    /// The switch is read HERE, per pass, rather than captured at build time:
    /// toggling it in Settings must take effect on the very next poll without
    /// rebuilding the account graph.
    private func notifyNewMail(_ changes: ChangeSet) async {
        guard let notifier, NotificationSettings.newMailEnabled(in: defaults) else { return }
        // Same per-pass rule for the per-domain switches (hidden, notify off).
        await notifier.handle(
            changes,
            accountID: accountID,
            accountLabel: accountLabel,
            silencedMailboxIDs: notificationSilencedMailboxIDs()
        )
    }

    /// Hands the pass to the classifier. The rules are resolved HERE, per pass,
    /// like the notification switches: a Workflows toggle or a gateway change
    /// applies to the very next poll.
    private func classifyNewMail(_ changes: ChangeSet) async {
        guard let classification, !changes.isBootstrap, !changes.inserted.isEmpty else { return }
        let context = ClassificationContextBuilder.context(
            accountID: accountID, domains: domains, labels: labels,
            defaults: defaults, secrets: classificationSecrets
        )
        await classification.handle(changes, accountID: accountID, context: context)
    }

    /// The engine labelled a thread behind the user's back: redraw its chips.
    func classificationApplied(threadID: String) async {
        await reloadIndexAfterLabelChange()
        await reloadSelectedMessageLabels()
    }

    /// Shows the conversation a clicked notification names.
    ///
    /// The banner may be minutes old and about a thread the current location
    /// does not show (another mailbox picked, a label open, a search typed,
    /// archived since), so this resets to All domains › Inbox with no label and
    /// clears the search before selecting — or to the thread's own domain ›
    /// Inbox when All domains leaves that domain out
    /// (``revealScope(forThread:)``). A thread that is genuinely gone leaves
    /// the UI on the inbox rather than selecting nothing in a mystery scope.
    func revealConversation(threadID: String) async {
        // How this reveal was reached is the CALLER's to say — the notification
        // router sets `.notification` before calling — so an unattributed reveal
        // is `other` like every other unlabelled navigation, rather than being
        // silently credited to a banner nobody clicked.
        let via = pendingNavigationSource ?? .other
        pendingNavigationSource = nil
        let wasShowingLabel = selectedLabelID != nil
        searchQuery = ""
        // ONE navigation for all three axes, so a click from Drafts or from
        // inside a label is one `view_shown`, never a drafts→inbox trail. The
        // label goes too: its rows are fetched by membership, and leaving it set
        // would have the reload fetch the label again, never find an unlabelled
        // inbox thread, and silently do nothing.
        var inbox = Location.launchDefault
        inbox.scope = await revealScope(forThread: threadID)
        if location != inbox {
            let changesView = location.scope != inbox.scope || location.folder != inbox.folder
            pendingNavigationSource = via
            navigate(to: inbox)
            // Leaving a label for the inbox that was already under it changes
            // neither scope nor folder, so `navigate` reports nothing; the click
            // still moved the user onto a different list.
            if !changesView, wasShowingLabel { recordViewShown(.inbox, via: via) }
            // `navigate` starts the reload; awaiting it is what makes the row
            // available to select below.
            await reloadTask?.value
        } else if isShowingThread {
            // Already on the inbox, but inside a thread: the click still moved
            // the user back to the conversation list.
            recordViewShown(.inbox, via: via)
        }
        leaveThreadSilently()
        if !allConversations.contains(where: { $0.id == threadID }) {
            await reloadConversations()
        }
        // Older than the loaded pages: page through the CACHE until it shows up
        // (never the server — a notification names mail a pass just stored).
        let revealLocation = location
        let revealGeneration = reloadGeneration
        while !allConversations.contains(where: { $0.id == threadID }), cacheMayHaveMoreConversations,
              isCurrentReload(revealLocation, revealGeneration), !Task.isCancelled {
            conversationListLimit += Self.conversationPageSize
            await reloadConversations()
        }
        guard allConversations.contains(where: { $0.id == threadID }) else {
            logger.info("Notification named a conversation that is no longer in the inbox")
            return
        }
        // Set only now, so a thread that turned out to be gone leaves nothing
        // stale behind for the user's next click to wear.
        pendingNavigationSource = via
        select(threadID, drill: true)
        pendingNavigationSource = nil
    }

    /// The scope a clicked banner lands in: All domains, unless the thread's
    /// inbox row sits in a domain that All domains leaves out — then that
    /// domain, or the click would reset to a list that can never hold the
    /// thread and select nothing.
    ///
    /// Only a domain kept out of All domains (`includeInAll == false`) takes
    /// that path in practice: a hidden domain never posts a banner. A banner
    /// that predates a hide still lands on All domains and finds nothing,
    /// which is right — the user asked not to see that domain.
    private func revealScope(forThread threadID: String) async -> Scope {
        // Nothing excluded: All domains lists every mailbox. No store read.
        guard let allDomainIDs = mailboxIDs(for: .allDomains) else { return .allDomains }
        let reachable = (try? await store.hasConversation(
            threadID: threadID, accountID: accountID, mailboxIDs: allDomainIDs, folder: .inbox
        )) ?? true
        guard !reachable else { return .allDomains }
        let messages = (try? await store.messages(accountID: accountID, threadID: threadID)) ?? []
        // The inbox copy first: that is the row the banner announced.
        let mailboxID = (messages.first { $0.folder == .inbox } ?? messages.first)?.mailboxID
        guard let mailboxID,
              let domain = domains.first(where: { $0.mailboxIDs.contains(mailboxID) }),
              !DomainPreferences.isHidden(accountID: accountID, domainID: domain.id, in: observedDefaults)
        else { return .allDomains }
        return .domain(domain.id)
    }

    /// Whether a change names a cached mailbox row (inserted or updated). One
    /// read of the account's (small) mailbox list.
    private func touchesMailbox(_ changes: ChangeSet) async -> Bool {
        guard !changes.isEmpty,
              let ids = try? await store.mailboxes(accountID: accountID).map(\.id)
        else { return false }
        return !changes.touched.isDisjoint(with: ids)
    }

    /// Reloads only the slices a change actually touched.
    ///
    /// The ``ChangeSet`` carries bare ids, so each one is resolved against the
    /// store: a message in another mailbox resolves to a row whose scope differs
    /// from ours and reloads nothing. Speculatively reloading everything on any
    /// change would defeat the change detection the store does.
    private func apply(_ changes: ChangeSet) async {
        guard !changes.isEmpty else { return }
        let touched = changes.touched
        var reloadConversationList = false
        var reloadThread = false
        var reloadMailboxList = false

        // Deletions cannot be resolved (the row is gone); if one hits something we
        // are showing, reload that slice.
        let visibleThreads = Set(allConversations.map(\.id))
        let visibleMessages = Set(threadMessages.map(\.id))
        for id in changes.deleted {
            if visibleThreads.contains(id) { reloadConversationList = true }
            if visibleMessages.contains(id) || id == selectedThreadID { reloadThread = true }
        }

        if touched.count > Self.maxResolvableChanges {
            // A bulk change (first sync, folder rebuild): resolving id by id would
            // cost more than the reload it is trying to avoid.
            reloadConversationList = true
            reloadThread = selectedThreadID != nil
            reloadMailboxList = true
        } else {
            // Resolved once for the pass, not once per changed message.
            let scopeIDs = mailboxIDs(for: location.scope)
            for id in changes.inserted.union(changes.updated) {
                guard let message = try? await store.message(id: id, accountID: accountID) else {
                    // Not a message id — a mailbox or a thread-only row.
                    if visibleThreads.contains(id) { reloadConversationList = true }
                    if id == selectedThreadID { reloadThread = true }
                    if !visibleThreads.contains(id) {
                        // A thread id that landed in the scope on screen but is not
                        // in it yet — the newly listed Trash row after a delete
                        // (issue #6): the list must pick it up.
                        if await conversationEnteredScope(id) {
                            reloadConversationList = true
                        } else {
                            // A brand-new mailbox is by definition NOT in `mailboxes`
                            // yet, so any remaining unresolved id must reload the
                            // (tiny) mailbox list — otherwise the sidebar stays empty
                            // after the very first sync of an account. Real-server
                            // finding 2026-08-15.
                            reloadMailboxList = true
                        }
                    }
                    continue
                }
                if message.threadID == selectedThreadID { reloadThread = true }
                // A message can resolve fine and still name a mailbox we have never
                // listed (added server-side since the last mailbox reload). Its row
                // would draw with no attribution (`ListColumn.AttributionIndex`
                // knows no local part for it). Mailboxes reload before
                // conversations below, so the attribution is there on the row's
                // first render.
                if let mailboxID = message.mailboxID, mailboxNames[mailboxID] == nil {
                    reloadMailboxList = true
                }
                if inScope(message, scopeIDs: scopeIDs) || visibleThreads.contains(message.threadID) {
                    reloadConversationList = true
                }
            }
        }

        if reloadMailboxList { await reloadMailboxes() }
        if reloadConversationList { await reloadConversations() }
        if reloadThread, let threadID = selectedThreadID { await loadThread(threadID) }
    }

    /// Cap on per-id resolution before falling back to a blanket reload.
    private static let maxResolvableChanges = 200

    /// Whether an unresolvable change id names a conversation row that now sits
    /// in the scope on screen.
    private func conversationEnteredScope(_ threadID: String) async -> Bool {
        guard let folder = location.folder.conversationFolder else { return false }
        do {
            return try await store.hasConversation(
                threadID: threadID,
                accountID: accountID,
                mailboxIDs: mailboxIDs(for: location.scope),
                folder: folder
            )
        } catch {
            logger.warning("Conversation scope check failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    /// Whether a changed message belongs to the list on screen. Deliberately
    /// NOT narrowed by the open label: a message can gain or lose the label in
    /// the very change being resolved, and a spare reload is cheap where a
    /// missed one leaves a row stranded.
    private func inScope(_ message: MessageSummary, scopeIDs: Set<String>?) -> Bool {
        guard let folder = location.folder.conversationFolder,
              Self.mailboxIDs(scopeIDs, contain: message.mailboxID)
        else { return false }
        return Self.conversationFolder(for: message.folder) == folder
    }

    nonisolated static func conversationFolder(for folder: MailFolder) -> ConversationFolder? {
        switch folder {
        case .inbox: .inbox
        case .sent: .sent
        case .archived: .archived
        case .trash: .trash
        case .catchall: .catchall
        case .drafts: nil
        }
    }

    // MARK: - Loads (all through MailStore)

    func reloadMailboxes() async {
        do {
            let loaded = try await store.mailboxes(accountID: accountID)
            let wasLoaded = !monogramMailboxes.isEmpty
            let wasDisabled = Set(disabledMailboxes.map(\.id))
            let hadDomains = domains
            // THE filter for server-disabled mailboxes and domains (see
            // ``mailboxes``). A scope standing on one that just went away falls
            // back to All domains in `correctStaleScope()`, like a hidden domain.
            mailboxes = loaded.filter(\.isEnabled)
            disabledMailboxes = loaded.filter { !$0.isEnabled }
            domains = MailDomain.domains(from: mailboxes)
            monogramDomains = MailDomain.domains(from: loaded)
            mailboxNames = Self.makeMailboxNames(loaded)
            mailboxListRevision &+= 1
            // What a scope RESOLVES to moved: a mailbox was switched off or
            // on, or one joined or left a domain. Reads in flight resolved the
            // old sets, so they must not publish (the reloads below replace
            // them). A rename moves nothing and costs nothing.
            let scopeSetsMoved = wasLoaded
                && (Set(disabledMailboxes.map(\.id)) != wasDisabled || domains != hadDomains)
            if scopeSetsMoved { reloadGeneration &+= 1 }
            let before = location
            correctStaleScope()
            // A server-side flip changes what a still-valid scope (All domains,
            // a domain keeping other mailboxes) lists, and nothing else would
            // reload it: the change that carried it names only the mailbox.
            // A scope correction already reloads through `navigate`.
            if scopeSetsMoved, location == before {
                await reloadConversations()
                await reloadDrafts()
            }
        } catch {
            logger.error("Mailbox load failed: \(error.localizedDescription, privacy: .private)")
        }
        await reloadUnreadCounts()
    }

    func reloadConversations() async {
        conversationReloadCount += 1
        // Captured BEFORE the await: two navigations in a row otherwise race,
        // and whichever store read finishes last wins — showing the previous
        // location's rows under the current one.
        let location = self.location
        let generation = reloadGeneration
        let mailboxIDs = mailboxIDs(for: location.scope)
        let limit = conversationListLimit
        do {
            let rows: [ConversationSummary]
            if let folder = location.folder.conversationFolder {
                if let labelID = location.labelID {
                    // Label ∩ folder ∩ scope — the label narrows the folder
                    // listing, it no longer spans every folder on its own.
                    rows = try await store.conversations(
                        withLabel: labelID, accountID: accountID, folder: folder, mailboxIDs: mailboxIDs,
                        limit: limit
                    )
                } else {
                    rows = try await store.conversations(
                        accountID: accountID, mailboxIDs: mailboxIDs, folder: folder, limit: limit
                    )
                }
            } else {
                // Drafts are listed by `reloadDrafts`; there are no conversation
                // rows under them. The index and the counts below still reload.
                rows = []
            }
            // BEFORE the rows are published, not after: macOS `List` caches a
            // measured height per row identity, so a row that first renders
            // without its label chips and grows a line afterwards stays clipped
            // at the height it was measured at (see the design-system note,
            // list row heights).
            await reloadLabelIndex()
            guard isCurrentReload(location, generation), !Task.isCancelled else { return }
            allConversations = rows
            cacheMayHaveMoreConversations = rows.count >= limit
            isLoadingConversations = false
        } catch {
            logger.error("Conversation load failed: \(error.localizedDescription, privacy: .private)")
            guard isCurrentReload(location, generation), !Task.isCancelled else { return }
            allConversations = []
            isLoadingConversations = false
        }
        // A server-search hit is by construction NOT in `allConversations`; the
        // union is what the user selected from, so it is the union that decides
        // whether the selection still exists. Checking the cache alone tore down
        // the reading pane on the next sync tick.
        if let selectedThreadID, conversation(withID: selectedThreadID) == nil {
            self.selectedThreadID = nil
        }
        refreshBodySearchIndex()
        await reloadUnreadCounts()
    }

    /// The list scrolled to its end: show the next page.
    ///
    /// From the cache while it holds more; past it, one server page per listing
    /// the sync pass capped. A failure leaves everything as it was, so the next
    /// time the end row appears is the retry.
    func loadMoreConversations() async {
        guard canLoadMoreConversations, !isLoadingMoreConversations,
              let folder = location.folder.conversationFolder else { return }
        let location = self.location
        let generation = reloadGeneration
        isLoadingMoreConversations = true
        defer { isLoadingMoreConversations = false }
        let visibleBefore = presentedConversations.count
        let cacheHadMore = cacheMayHaveMoreConversations
        if !cacheMayHaveMoreConversations {
            // A search that filtered the list down leaves this row on screen,
            // and it would keep pulling server pages on its own; server search
            // is what answers a search past the cache.
            guard searchQuery.isEmpty else { return }
            guard let sync else {
                serverMayHaveMoreConversations = false
                return
            }
            let mayHaveMore: Bool
            do {
                mayHaveMore = try await sync.loadOlderConversations(
                    mailboxIDs: mailboxIDs(for: location.scope), folder: folder
                )
            } catch {
                logger.warning("Loading older conversations failed: \(error.localizedDescription, privacy: .private)")
                return
            }
            guard isCurrentReload(location, generation), !Task.isCancelled else { return }
            serverMayHaveMoreConversations = mayHaveMore
        }
        conversationListLimit += Self.conversationPageSize
        await reloadConversations()
        guard isCurrentReload(location, generation) else { return }
        let addedRows = presentedConversations.count > visibleBefore
        let serverIsNext = cacheHadMore && !cacheMayHaveMoreConversations && searchQuery.isEmpty
        if addedRows || serverIsNext { loadMoreTrigger &+= 1 }
    }

    /// The unread badges — only the counts something draws.
    ///
    /// ONE store read (``MailStore/unreadConversationKeys(accountID:)``: every
    /// unread row's thread, mailbox and folder) and everything else in memory
    /// (``UnreadTally``). It used to be a `fetchCount` per mailbox plus one per
    /// folder and per aggregate — serial actor hops that grew with the account
    /// (160 mailboxes, 167 hops) on every conversation reload — and it summed
    /// per-mailbox numbers, counting a thread in two mailboxes twice.
    ///
    /// Five kinds of count, each drawn somewhere, each over DISTINCT threads:
    /// - every sidebar folder of the CURRENT scope (the folder rows), including
    ///   Starred;
    /// - the inbox of every mailbox (the mailbox rows);
    /// - the inbox of every domain;
    /// - the inbox of All domains, over the SAME set the All domains listing
    ///   reads (with nothing excluded that is every row, including any whose
    ///   mailbox the mailbox list does not hold);
    /// - the Dock badge's inbox — the same, over ``badgeMailboxIDs()``.
    ///
    /// Publishes only if no navigation, preference write or mailbox change
    /// landed while the store answered (``reloadGeneration``) — whoever bumped
    /// it runs a fresh count.
    private func reloadUnreadCounts() async {
        let generation = reloadGeneration
        let scopeIDs = mailboxIDs(for: location.scope)
        let allDomainIDs = mailboxIDs(for: .allDomains)
        let badgeIDs = badgeMailboxIDs()
        let mailboxIDs = mailboxes.map(\.id)
        let domains = self.domains
        let folders = MailTheme.sidebarFolders
        let keys: [UnreadConversationKey]
        do {
            keys = try await store.unreadConversationKeys(accountID: accountID)
        } catch {
            logger.error("Unread count failed: \(error.localizedDescription, privacy: .private)")
            return
        }
        // Set work over every unread row of the account; not on the main actor.
        let tally = await Task.detached(priority: .userInitiated) { @Sendable in
            UnreadTally(
                keys: keys, scopeIDs: scopeIDs, folders: folders,
                mailboxIDs: mailboxIDs, domains: domains,
                allDomainIDs: allDomainIDs, badgeIDs: badgeIDs
            )
        }.value
        countsWillPublish?()
        guard generation == reloadGeneration else { return }
        folderUnreadCounts = tally.byFolder
        inboxUnreadByMailbox = tally.byMailbox
        inboxUnreadByDomain = tally.byDomain
        allDomainsInboxUnread = tally.allDomains
        badgeInboxUnread = tally.badge
        unreadCountDidChange?(tally.badge)
    }

    /// Whether a reload that captured `location` and `generation` before its
    /// store read still answers what is on screen.
    func isCurrentReload(_ location: Location, _ generation: Int) -> Bool {
        location == self.location && generation == reloadGeneration
    }

    private nonisolated static func makeMailboxNames(_ mailboxes: [Mailbox]) -> [String: String] {
        var names: [String: String] = [:]
        names.reserveCapacity(mailboxes.count)
        for mailbox in mailboxes {
            names[mailbox.id] = mailbox.displayName.isEmpty ? mailbox.address : mailbox.displayName
        }
        return names
    }

    func loadThread(_ threadID: String) async {
        threadReloadCount += 1
        do {
            var messages = try await store.messages(accountID: accountID, threadID: threadID)
            guard !Task.isCancelled, selectedThreadID == threadID else { return }
            if messages.isEmpty, let row = serverResults.first(where: { $0.id == threadID }) {
                messages = await serverThreadMessages(for: row)
                guard !Task.isCancelled, selectedThreadID == threadID else { return }
            }
            threadMessages = messages
            if selectedMessageID == nil || !messages.contains(where: { $0.id == selectedMessageID }) {
                // Newest first, so the newest is the head of the list.
                selectedMessageID = messages.first?.id
            }
        } catch {
            logger.error("Thread load failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// The messages of a thread the CACHE does not hold — a row the server search
    /// found that sync has not listed yet.
    ///
    /// The row already carries its newest message, so the fallback is never
    /// empty: a failed (or offline) thread fetch still opens on the message the
    /// search matched rather than on a blank pane.
    private func serverThreadMessages(for row: ConversationSummary) async -> [MessageSummary] {
        guard row.messageCount > 1 else { return [row.latest] }
        do {
            let details = try await api.thread(messageID: row.latest.id)
            let messages = details.map(\.summary)
            // The thread route embeds labels as well. These messages are NOT in
            // the message cache (that is why this path exists), but an assignment
            // row does not need one — the reconciliation stores rows for uncached
            // messages by design — so the chips are right the moment the thread
            // opens instead of at the next reconciliation.
            await storeEmbeddedLabels(of: messages)
            return messages.isEmpty ? [row.latest] : messages.sorted { $0.displayDate > $1.displayDate }
        } catch {
            logger.warning("Server-search thread load failed: \(error.localizedDescription, privacy: .private)")
            return [row.latest]
        }
    }

    // MARK: - Message detail and body

    private func loadDetail(_ messageID: String) async {
        isLoadingBody = true
        // Only the load for the CURRENT selection may clear the flag: a superseded
        // load finishing late would otherwise hide the spinner for the new one.
        defer { if selectedMessageID == messageID { isLoadingBody = false } }
        do {
            // The single-message route is the authoritative source (never a list
            // route): it is the only one carrying attachments and the full
            // recipient list.
            let loaded = try await api.message(id: messageID)
            guard !Task.isCancelled, selectedMessageID == messageID else { return }
            detail = loaded
            // The single-message route embeds labels too, and this is the freshest
            // statement about them the app ever gets — the user is looking at the
            // chips right now. A no-op on a pre-1.4.2 server (`labels == nil`).
            await storeEmbeddedLabels(of: [loaded.summary])
            await loadBody(for: loaded, allowRemote: false)
        } catch {
            logger.warning("Message detail failed: \(error.localizedDescription, privacy: .private)")
            guard selectedMessageID == messageID else { return }
            // Offline (or a flaky detail route) used to blank the whole pane
            // header AND the attachment bar while the body still rendered from
            // cache. Rebuild a detail from the cache instead.
            // A DECODING failure is the server contract breaking (an instance
            // older than the `disposition` field, say) — every message would fail
            // the same way, and quietly serving cached detail forever would hide
            // it. Only a transport/availability failure earns the fallback.
            if !Self.isContractFailure(error), let cached = await cachedDetail(messageID: messageID) {
                guard selectedMessageID == messageID else { return }
                detail = cached
                await loadBody(for: cached, allowRemote: false)
            } else {
                actionError = error.localizedDescription
            }
        }
    }

    /// Whether the error says the response itself was unusable rather than
    /// unreachable.
    private nonisolated static func isContractFailure(_ error: any Error) -> Bool {
        if case MailAPIError.decoding = error { return true }
        return false
    }

    /// A `MessageDetail` reassembled from the cache: the summary row plus the
    /// body sidecar (which carries the attachment metadata). Recipients the cache
    /// never held (cc/bcc) come back empty — deliberately, rather than wrongly.
    private func cachedDetail(messageID: String) async -> MessageDetail? {
        guard let summary = try? await store.message(id: messageID, accountID: accountID) else { return nil }
        let cached = try? await store.cachedBody(messageID: messageID, accountID: accountID)
        guard let cached else { return nil }
        return MessageDetail(
            summary: summary,
            cc: [],
            bcc: [],
            deliveredToAddress: nil,
            textBody: cached.textBody,
            htmlAvailable: cached.html != nil,
            rfcMessageID: nil,
            inReplyTo: nil,
            references: [],
            attachments: cached.attachments
        )
    }

    private func loadBody(for detail: MessageDetail, allowRemote: Bool) async {
        let messageID = detail.id
        // Cleared per load, not only inside `inlineImages`: the plain-text path
        // never calls that, so a previous message's count used to stay on screen.
        inlineImagesUnavailable = 0
        // The subject becomes the document's <title>: VoiceOver announces the web
        // area by it, and an untitled web area is announced as "HTML content".
        let title = detail.summary.subject
        guard detail.htmlAvailable else {
            let text = detail.textBody
            let rendered = await Task.detached(priority: .userInitiated) { @Sendable in
                Self.document(wrappingPlainText: text, title: title)
            }.value
            guard selectedMessageID == messageID else { return }
            body = RenderedBody(messageID: messageID, html: rendered, blocksRemote: true, offersRemoteConsent: false)
            await cacheBody(messageID: messageID, text: text, html: nil, attachments: detail.attachments)
            return
        }

        do {
            let payload = try await api.messageHTML(id: messageID, loadRemoteImages: allowRemote)
            guard !Task.isCancelled, selectedMessageID == messageID else { return }
            let inline = await inlineImages(for: detail)
            guard !Task.isCancelled, selectedMessageID == messageID else { return }
            // All three authored fragments, not just the first: `afterQuotedHTML`
            // is text the sender wrote BELOW the quote, and rendering only `html`
            // silently dropped it.
            let composed = Self.composeBody(
                html: payload.html,
                quotedHTML: payload.quotedHTML,
                afterQuotedHTML: payload.afterQuotedHTML
            )
            // Substitution walks the whole body; never on the main actor.
            let substituted = await Task.detached(priority: .userInitiated) { @Sendable in
                Self.document(
                    wrapping: Self.substituteInlineImages(in: composed, with: inline),
                    title: title,
                    allowsRemote: allowRemote
                )
            }.value
            guard selectedMessageID == messageID else { return }
            body = RenderedBody(
                messageID: messageID,
                html: substituted,
                blocksRemote: !allowRemote,
                offersRemoteConsent: payload.needsRemoteMediaConsent && !allowRemote,
                // Quoted history is collapsed by default: when that is the only
                // place the blocked images live, the banner says so rather than
                // pointing at a body with no pictures in it. It is still OFFERED —
                // expanding the history is one click, and this banner is the only
                // route to trusting the sender.
                remoteConsentIsForQuotedHistoryOnly: payload.remoteImagesAreOnlyInQuotedHistory
            )
            await cacheBody(
                messageID: messageID,
                text: detail.textBody,
                // The COMPOSED fragment is what the cache holds: the sidecar has
                // one HTML column, and caching `payload.html` alone would lose the
                // quoted history and the after-quote text on every offline read.
                html: composed,
                attachments: detail.attachments
            )
        } catch {
            logger.warning("Message HTML failed: \(error.localizedDescription, privacy: .private)")
            guard selectedMessageID == messageID else { return }
            // Fall back to the cached copy so an offline read still shows something.
            if let cached = try? await store.cachedBody(messageID: messageID, accountID: accountID), let html = cached.html {
                // The cached HTML still holds raw `cid:` references; without the
                // substitution every inline image in an offline read is a broken
                // image (the CSP forbids the web view fetching `cid:` itself).
                // The inline route may well be up when the HTML route is not.
                let inline = await inlineImages(for: detail)
                guard !Task.isCancelled, selectedMessageID == messageID else { return }
                let wrapped = await Task.detached(priority: .userInitiated) { @Sendable in
                    // `allowsRemote` was dropped here: a reader who had already
                    // trusted the sender got the strict CSP back on the offline
                    // render, with every remote image broken.
                    Self.document(
                        wrapping: Self.substituteInlineImages(in: html, with: inline),
                        title: title,
                        allowsRemote: allowRemote
                    )
                }.value
                guard selectedMessageID == messageID else { return }
                body = RenderedBody(
                    messageID: messageID, html: wrapped,
                    blocksRemote: !allowRemote, offersRemoteConsent: false
                )
            } else {
                actionError = error.localizedDescription
            }
        }
    }

    private func cacheBody(messageID: String, text: String, html: String?, attachments: [Attachment]) async {
        do {
            try await store.storeBody(
                messageID: messageID,
                accountID: accountID,
                textBody: text,
                html: html,
                attachments: attachments
            )
        } catch {
            logger.error("Body cache write failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Fetches inline parts as data so `cid:` references can be rewritten. The
    /// web view is never allowed to fetch them itself.
    /// Concurrent: a message with eight inline parts used to cost eight
    /// round trips end to end, with the reading pane blank throughout. The group
    /// also keeps the base64 encoding off the main actor.
    private func inlineImages(for detail: MessageDetail) async -> [String: String] {
        let inlineParts = detail.attachments.filter(\.isInline)
        guard !inlineParts.isEmpty else { return [:] }
        let api = self.api
        let messageID = detail.id
        return await withTaskGroup(of: (String, String)?.self) { group in
            for part in inlineParts {
                guard let contentID = part.contentID else { continue }
                let partID = part.id
                group.addTask { @Sendable in
                    do {
                        let payload = try await api.inlineImage(messageID: messageID, attachmentID: partID)
                        // The MIME type rides into a `data:` URL the web view will
                        // honour. A part claiming `text/html` (or anything
                        // scriptable) must never become a substitutable data: URL,
                        // whatever the part metadata says.
                        guard Self.isRenderableInlineMedia(payload.mimeType) else {
                            logger.warning("Inline part \(partID, privacy: .public) is not renderable media; skipped")
                            return nil
                        }
                        return (
                            Self.normalizedContentID(contentID),
                            "data:\(payload.mimeType);base64,\(payload.data.base64EncodedString())"
                        )
                    } catch {
                        logger.warning("Inline image \(partID, privacy: .public) unavailable")
                        return nil
                    }
                }
            }
            var result: [String: String] = [:]
            var failures = 0
            for await entry in group {
                guard let entry else {
                    failures += 1
                    continue
                }
                result[entry.0] = entry.1
            }
            // Inline failures used to be entirely silent: the reader saw a body
            // with holes in it and no reason why. Only the CURRENT selection's
            // load may publish a count; a superseded load must not label the
            // message that replaced it.
            if selectedMessageID == messageID { inlineImagesUnavailable = failures }
            return result
        }
    }

    /// User consented to remote media for this sender: tell the server (so the
    /// web app agrees) and re-render without the blocking rule list.
    func trustRemoteMedia() async {
        guard let detail else { return }
        do {
            try await api.trustRemoteMedia(messageID: detail.id)
        } catch {
            logger.warning("Remote-media trust failed: \(error.localizedDescription, privacy: .private)")
            actionError = error.localizedDescription
            return
        }
        record(.remoteMediaLoaded)
        await loadBody(for: detail, allowRemote: true)
    }

    // MARK: - Compose

    /// Every address this account owns, across all its mailboxes — disabled
    /// ones included: they are still the user's, and reply-all subtracts
    /// these, so leaving one out would CC the user themselves.
    var ownAddresses: [String] {
        EmailAddress.dedupe((mailboxes + disabledMailboxes).flatMap { [$0.address] + $0.addresses.map(\.address) })
    }

    /// The address a message from `mailboxID` should be sent from: the mailbox's
    /// primary send-enabled address, falling back to its main address. A
    /// disabled mailbox still answers with its OWN address (a stored draft
    /// keeps the From that matches its mailbox — the server refuses the send);
    /// ``composeContext(for:)`` keeps new mail and replies off disabled ones.
    func sendAddress(forMailbox mailboxID: String?) -> String {
        let fallback = defaultComposeMailboxID().flatMap { id in mailboxes.first { $0.id == id } }
        guard let mailbox = monogramMailboxes.first(where: { $0.id == mailboxID }) ?? fallback else {
            return ""
        }
        return mailbox.sendableAddresses.first?.address ?? mailbox.address
    }

    /// The mailbox a message with nothing to tie it to (a new message with no
    /// selection, or one whose mailbox the server switched off) is sent from:
    /// the first enabled mailbox of the scope on screen — the mailbox itself,
    /// the domain's first, or under All domains the first mailbox of a domain
    /// All domains shows — then any mailbox of a domain that is not hidden.
    ///
    /// NEVER a hidden domain's: the user took it out of Herald, and a new
    /// message silently leaving from it was the old `mailboxes.first`. `nil`
    /// when every enabled mailbox is in a hidden domain — the composer then
    /// opens with no From rather than a hidden one.
    func defaultComposeMailboxID() -> String? {
        let visible = composableMailboxes().map(\.id)
        let scopeIDs = mailboxIDs(for: scope)
        // `visible` keeps the mailbox list's order, so "first" is stable.
        return visible.first { Self.mailboxIDs(scopeIDs, contain: $0) } ?? visible.first
    }

    /// The enabled mailboxes a message may start from on its own: every one
    /// not in a domain the user hid, in the mailbox list's order.
    func composableMailboxes() -> [Mailbox] {
        let defaults = observedDefaults
        let hidden = Set(domains
            .filter { DomainPreferences.isHidden(accountID: accountID, domainID: $0.id, in: defaults) }
            .flatMap(\.mailboxIDs))
        return mailboxes.filter { !hidden.contains($0.id) }
    }

    /// The From a compose request starts with (V5, spec §3.3 / §4):
    /// - a NEW message with no mailbox of its own: the scope's address, then
    ///   the account primary (``ComposeFrom/defaultAddress(scope:mailboxes:domains:domainDefaultFrom:)``);
    ///   a domain scope honours the domain's "Default From address" preference;
    /// - a reply, reply-all or forward: the address of its mailbox the original
    ///   was actually sent to (``ComposeFrom/replyAddress(for:in:)``) — mail to
    ///   sales@ is answered from sales@ even when the mailbox's primary is info@;
    /// - otherwise the mailbox's primary (``sendAddress(forMailbox:)``).
    /// Drafts keep their stored From (``composeContext(for:)``).
    func composeFrom(kind: ComposeRequest.Kind, mailboxID: String?, message: MessageDetail?) -> (mailboxID: String?, address: String) {
        if kind == .new, mailboxID == nil {
            var domainDefaultFrom: String?
            if case .domain(let domainID) = scope {
                domainDefaultFrom = DomainPreferences.defaultFrom(
                    accountID: accountID, domainID: domainID, in: observedDefaults
                )
            }
            if let address = ComposeFrom.defaultAddress(
                scope: scope, mailboxes: composableMailboxes(), domains: domains, domainDefaultFrom: domainDefaultFrom
            ) {
                return (address.mailboxID, address.address)
            }
            let fallback = defaultComposeMailboxID()
            return (fallback, fallback == nil ? "" : sendAddress(forMailbox: fallback))
        }
        if let message, kind != .new,
           let mailbox = monogramMailboxes.first(where: { $0.id == mailboxID }),
           let address = ComposeFrom.replyAddress(for: message, in: mailbox) {
            return (mailboxID, address.address)
        }
        return (mailboxID, sendAddress(forMailbox: mailboxID))
    }

    static let disabledMailboxReplyError = "This mailbox is turned off on the server, so you can't reply from it."

    /// Resolves a compose request into everything the composer needs.
    ///
    /// The already-loaded ``detail`` is reused when the request is about the
    /// selected message (the common case: ⌘R on what you are reading); anything
    /// else costs one message fetch.
    func composeContext(for request: ComposeRequest) async -> ComposeContext? {
        // Reopening a stored draft: everything the composer needs — recipients,
        // body, attachments and the version stamp — is already in the cache.
        if request.kind == .draft {
            guard let draftID = request.draftID else { return nil }
            let stored: Draft?
            do {
                stored = try await store.draft(id: draftID, accountID: accountID)
            } catch {
                logger.error("Draft load for compose failed: \(error.localizedDescription, privacy: .private)")
                return nil
            }
            guard let stored else {
                // Deleted (or sent) between the double-click and here.
                actionError = "That draft is no longer available."
                return nil
            }
            let mailboxID = stored.content.mailboxID
            return ComposeContext(
                id: request.id,
                kind: .draft,
                mailboxID: mailboxID,
                fromAddress: stored.content.from.isEmpty ? sendAddress(forMailbox: mailboxID) : stored.content.from,
                ownAddresses: ownAddresses,
                storedDraft: stored,
                fromMailboxes: mailboxes
            )
        }

        var message: MessageDetail?
        if request.kind != .new, let messageID = request.messageID {
            if detail?.id == messageID {
                message = detail
            } else {
                do {
                    message = try await api.message(id: messageID)
                } catch {
                    logger.warning("Compose could not load its message: \(error.localizedDescription, privacy: .private)")
                    actionError = error.localizedDescription
                    return nil
                }
            }
        }
        var mailboxID = message?.summary.mailboxID ?? request.mailboxID
        if let id = mailboxID, disabledMailboxes.contains(where: { $0.id == id }) {
            // A reply or forward belongs to its mailbox: sending it from
            // another one would silently change who the customer hears from.
            guard request.kind == .new else {
                actionError = Self.disabledMailboxReplyError
                return nil
            }
            // A brand-new message has no such tie.
            mailboxID = nil
        }
        // Nothing ties a new message to a mailbox: the scope's, never a
        // hidden domain's.
        let from = composeFrom(kind: request.kind, mailboxID: mailboxID, message: message)
        return ComposeContext(
            id: request.id,
            kind: request.kind,
            mailboxID: from.mailboxID,
            fromAddress: from.address,
            ownAddresses: ownAddresses,
            message: message,
            fromMailboxes: mailboxes
        )
    }

    // MARK: - Mark read after dwell

    /// A message is only marked read once it has held the selection for
    /// ``markReadDelay``; the task is cancelled the moment the selection moves,
    /// so arrowing past a message leaves it unread.
    private func markReadAfterDwell(_ messageID: String) async {
        do {
            try await Task.sleep(for: markReadDelay)
        } catch {
            // Cancelled by a new selection: deliberately do NOT mark read.
            return
        }
        guard !Task.isCancelled, selectedMessageID == messageID else { return }
        guard let message = try? await store.message(id: messageID, accountID: accountID), message.isUnread else { return }
        do {
            try await actions.perform(.read, on: messageID, accountID: accountID)
        } catch {
            logger.warning("Auto mark-read failed: \(error.localizedDescription, privacy: .private)")
            return
        }
        await reloadConversations()
        if let threadID = selectedThreadID { await loadThread(threadID) }
    }
}
