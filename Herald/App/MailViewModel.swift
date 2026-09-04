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
    func setCadence(_ cadence: SyncCadence) async
}

extension SyncEngine: MailSyncing {}

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

    /// A mailbox + folder pair, i.e. one conversation-list scope.
    nonisolated struct FolderSelection: Hashable, Sendable {
        var mailboxID: String?
        var folder: ConversationFolder
    }

    /// What the sidebar's list is selecting.
    ///
    /// Drafts is NOT a ``ConversationFolder``: the server has no drafts
    /// conversation folder (the conversation enum swaps `drafts` for `starred`),
    /// drafts are not messages, and `GET /messages?folder=drafts` is dead. So it
    /// is a special sidebar item wrapping the folder scope rather than a member
    /// of it — which also keeps ``selection`` typed as the conversation scope
    /// everything else already reads.
    nonisolated enum SidebarItem: Hashable, Sendable {
        case folder(FolderSelection)
        case drafts
    }

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
    private let events: AsyncStream<SyncEvent>
    /// How long a message must stay selected before it is marked read. Injected
    /// so tests can drive both sides of the rule without real waiting.
    private let markReadDelay: Duration
    /// Where per-mailbox colour overrides and the alert switches live. Injected
    /// so a test drives a throwaway suite instead of the user's real preferences.
    private let defaults: UserDefaults
    /// Posts new-mail banners for this account. `nil` in tests that are not about
    /// notifications, and in any build where the user turned them off.
    private let notifier: NewMailNotifier?
    /// Called with the all-mailboxes inbox unread count whenever it is recomputed
    /// — the Dock badge's only input. A closure rather than an observation loop
    /// so the badge updates exactly when the count does. Observation-ignored: no
    /// view reads it, and assigning it would otherwise invalidate every observer.
    @ObservationIgnored var unreadCountDidChange: (@MainActor (Int) -> Void)?
    /// Called with this account's id the moment sync decides only a fresh
    /// sign-in can fix things — on the TRANSITION into ``SyncStatus/needsReauth``
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

    /// The view the middle column is showing right now.
    private var currentViewKind: UsageViewKind {
        if isShowingThread { return .thread }
        if isShowingDrafts { return .drafts }
        return Self.viewKind(for: selection.folder)
    }

    /// Raised around an assignment that changes the scope WITHOUT being a view the
    /// user reached — today only the launch restore correcting the mailbox behind
    /// a launch view that has already been reported. Only ever set for the
    /// duration of one synchronous assignment, so nothing can observe it down
    /// across a suspension.
    @ObservationIgnored private var suppressesViewShown = false

    /// Records one `view_shown`. Internal so the drafts extension can call it.
    func recordViewShown(_ view: UsageViewKind, via: UsageViewTrigger) {
        guard !suppressesViewShown else { return }
        record(.viewShown(view: view, via: via))
    }

    /// The sidebar restoring the mailbox scope the window was last showing.
    ///
    /// This races ``start()``: SwiftUI runs the restore task whenever the mailbox
    /// list first arrives, which can be before or after the view-model started.
    /// Whichever gets here first reports THE launch view; the other stays silent,
    /// so a launch is exactly one `view_shown` either way.
    func restoreSelection(_ scope: FolderSelection) {
        guard scope != selection else { return }
        if didRecordLaunchView {
            // The launch view is already out; this only corrects which mailbox
            // it was showing, and is not a second view.
            suppressesViewShown = true
            defer { suppressesViewShown = false }
            pendingNavigationSource = nil
            selection = scope
        } else {
            didRecordLaunchView = true
            pendingNavigationSource = .launch
            selection = scope
        }
    }

    /// Consumes the pending source even when nothing changed — see
    /// ``pendingNavigationSource``. Internal for the drafts extension.
    func takeNavigationSource() -> UsageViewTrigger { consumeNavigationSource() }

    // MARK: Published state

    private(set) var mailboxes: [Mailbox] = []
    /// mailbox id → the name a row should attribute a message to. Built once per
    /// mailbox reload: the "All Mailboxes" list draws this on EVERY row, and a
    /// `mailboxes.first(where:)` per row is a linear scan per row per render.
    private(set) var mailboxNames: [String: String] = [:]
    /// mailbox id → address, the input the default colour is derived from. Same
    /// reason as `mailboxNames`: the chip is drawn on every row.
    private(set) var mailboxAddresses: [String: String] = [:]
    /// mailbox id → the palette token the user explicitly picked. Observed, so a
    /// change in Settings repaints the open list without a reload; only ids with
    /// an override appear.
    private(set) var mailboxColorOverrides: [String: String] = [:]
    /// Unread conversation counts per (mailbox, folder) scope.
    private(set) var unreadCounts: [FolderSelection: Int] = [:]

    var selection: FolderSelection {
        didSet {
            // Consumed BEFORE the guard: re-picking the folder that is already
            // showing is a navigation that happened, and leaving its `via` behind
            // would mislabel whatever the user does next.
            let via = consumeNavigationSource()
            guard selection != oldValue else { return }
            recordViewShown(Self.viewKind(for: selection.folder), via: via)
            selectedThreadID = nil
            // Server search is scoped to (mailbox, folder): its rows answer the
            // OLD scope's question and would leak into the new folder's list.
            cancelServerSearch()
            // The folder is half of the presentation rule, so the visible list is
            // wrong until it is recomputed — don't wait for the store round trip.
            refilter()
            // Cancel first: replacing a running task leaves the older, slower
            // reload alive to finish last and overwrite the newer scope's rows.
            reloadTask?.cancel()
            reloadTask = Task { await reloadConversations() }
        }
    }

    // MARK: Drafts
    //
    // Storage only. Every write to these lives in `MailViewModel+Drafts.swift`,
    // which owns the drafts behaviour; they are plain `var`s rather than
    // `private(set)` because `private` in Swift does not reach an extension in
    // another file, and the alternative was to inline the whole feature here.

    /// Whether the middle column is showing the Drafts folder instead of a
    /// conversation list. Written only through ``showDrafts(_:)``.
    var isShowingDrafts = false
    /// The drafts list, newest edit first. Sendable DTOs — the list never sees a
    /// `@Model` and never holds a draft body.
    var drafts: [DraftSummary] = []
    /// The sidebar badge. Counted in the store (`fetchCount`), never by loading rows.
    var draftCount = 0
    var selectedDraftID: String?

    /// Instrumentation, same contract as the conversation counter: it exists so
    /// "the drafts list reloaded exactly once" is assertable.
    @ObservationIgnored var draftReloadCount = 0
    /// The in-flight drafts load, owned so ``stop()`` can cancel it.
    @ObservationIgnored var draftTask: Task<Void, Never>?

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
    /// dropped on the floor.
    @ObservationIgnored private(set) var reloadTask: Task<Void, Never>?
    private var threadTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
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
        notifier: NewMailNotifier? = nil,
        record: @escaping @MainActor @Sendable (UsageEvent) -> Void = { _ in }
    ) {
        self.record = record
        self.defaults = defaults
        self.notifier = notifier
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.api = api
        self.store = store
        self.actions = actions
        self.sync = sync
        self.events = events
        self.markReadDelay = markReadDelay
        self.selection = FolderSelection(mailboxID: nil, folder: .inbox)
    }

    /// Stops consuming sync events. Called when the account is torn down —
    /// `deinit` cannot do it, being nonisolated.
    func stop() {
        eventTask?.cancel()
        reloadTask?.cancel()
        threadTask?.cancel()
        detailTask?.cancel()
        markReadTask?.cancel()
        bodyIndexTask?.cancel()
        cancelServerSearch()
        draftTask?.cancel()
    }

    // MARK: - Derived state

    /// Recomputes ``presentedConversations``. The ONLY writer of it, called from
    /// the `didSet` of each of the three inputs the filter depends on.
    private func refilter() {
        filterCount += 1
        let folder = selection.folder
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
            var seen = Set(rows.map(\.id))
            for row in serverResults where Self.belongs(row, to: folder) && seen.insert(row.id).inserted {
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
                scope: .local, results: UsageBucket(count: presentedConversations.count)
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
        let scope = selection
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

    private func performServerSearch(_ query: String, scope: FolderSelection) async {
        var collected: [ConversationSummary] = []
        var seen: Set<String> = []
        var cursor: String?
        var page = 0

        while page < Self.maxServerSearchPages {
            let result: ConversationPage
            do {
                result = try await api.listConversations(
                    folder: scope.folder,
                    mailboxID: scope.mailboxID,
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
            for row in result.conversations where seen.insert(row.id).inserted {
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
    private func isCurrentSearch(_ query: String, _ scope: FolderSelection) -> Bool {
        selection == scope
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

    // MARK: - Mailbox colour

    /// The palette token a mailbox draws in: the user's override if there is one,
    /// otherwise the address-derived default. `nil` only for an unknown id.
    func mailboxColorToken(for id: String?) -> String? {
        guard let id, let address = mailboxAddresses[id] else { return nil }
        return MailboxColorAssignment.token(
            forAddress: address, override: mailboxColorOverrides[id]
        )
    }

    /// The resolved tint, ready for the chip. Views ask for this, never for a
    /// `Color` of their own.
    func mailboxTint(for id: String?) -> MailboxTint? {
        guard let token = mailboxColorToken(for: id) else { return nil }
        return MailTheme.mailboxTint(named: token)
    }

    /// Whether this mailbox is currently on its default colour — what the
    /// "Reset to Default" button keys off.
    func hasMailboxColorOverride(_ id: String) -> Bool {
        mailboxColorOverrides[id] != nil
    }

    /// Sets (or, with `nil`, clears) one mailbox's colour. Writing straight
    /// through to `UserDefaults` AND to the observed map: the map is what repaints
    /// the list, the defaults write is what survives relaunch.
    func setMailboxColorToken(_ token: String?, for mailboxID: String) {
        // No props: the token is a colour NAME the user chose per mailbox, and
        // the mailbox id is an identifier. Neither may be reported.
        record(.mailboxColorChanged)
        let key = MailboxColorAssignment.storageKey(accountID: accountID, mailboxID: mailboxID)
        if let token, MailTheme.mailboxTint(named: token) != nil {
            mailboxColorOverrides[mailboxID] = token
            defaults.set(token, forKey: key)
        } else {
            mailboxColorOverrides[mailboxID] = nil
            defaults.removeObject(forKey: key)
        }
    }

    private func loadMailboxColorOverrides(for mailboxes: [Mailbox]) {
        var overrides: [String: String] = [:]
        for mailbox in mailboxes {
            let key = MailboxColorAssignment.storageKey(
                accountID: accountID, mailboxID: mailbox.id
            )
            guard let stored = defaults.string(forKey: key),
                  MailTheme.mailboxTint(named: stored) != nil
            else { continue }
            overrides[mailbox.id] = stored
        }
        mailboxColorOverrides = overrides
    }

    /// Unread count behind one picker entry (`nil` = every mailbox). Inbox only:
    /// that is the scope ``unreadCounts`` carries per mailbox.
    func pickerUnread(forMailbox id: String?) -> Int {
        unreadCounts[FolderSelection(mailboxID: id, folder: .inbox)] ?? 0
    }

    /// One line of the mailbox picker. Pure and static so the label the popup
    /// shows is assertable without a rendered `Picker`.
    nonisolated static func pickerLabel(for mailbox: Mailbox, unread: Int) -> String {
        let name = mailbox.displayName.isEmpty ? mailbox.address : mailbox.displayName
        let base = name == mailbox.address ? name : "\(name) — \(mailbox.address)"
        return unread > 0 ? "\(base) (\(unread))" : base
    }

    nonisolated static func allMailboxesPickerLabel(unread: Int) -> String {
        unread > 0 ? "All mailboxes (\(unread))" : "All mailboxes"
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
        await reloadConversations()
        await reloadDrafts()
        // The launch view has to be said out loud: `selection` is assigned in
        // `init`, where a `didSet` does not fire, so nothing else reports the
        // folder the window comes up on. Once per view-model — a re-`start()`
        // (there is none today) must not double-count a launch.
        guard !didRecordLaunchView else { return }
        didRecordLaunchView = true
        pendingNavigationSource = nil
        recordViewShown(currentViewKind, via: .launch)
    }

    @ObservationIgnored private var didRecordLaunchView = false

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
        await sync?.setCadence(active ? .active : .idle)
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
                // Before the reloads: the banner is about what ARRIVED, and the
                // reload path can take several store round trips.
                await notifyNewMail(changes)
                await apply(changes)
            case .draftsChanged(let changes):
                if !changes.isEmpty { passChangedAnything = true }
                await applyDraftChanges(changes)
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
                    let isNewExpiry = status != .needsReauth
                    status = .needsReauth
                    if isNewExpiry { reauthenticationRequired?(accountID) }
                } else {
                    status = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Every failure that only a fresh sign-in can fix must land on the re-auth
    /// banner, whose button re-runs consent — not on "Sync problem / Retry", where
    /// Retry just repeats the doomed refresh (issue #1: "not granted offline
    /// access" after ~1 h, Retry did nothing). Covers a rejected token, a refresh
    /// the server refused, and a missing refresh token, however deeply the API
    /// layer wrapped it.
    nonisolated static func requiresReauthentication(_ error: any Error) -> Bool {
        if let api = error as? MailAPIError { return api == .unauthorized }
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
        await notifier.handle(changes, accountID: accountID, accountLabel: accountLabel)
    }

    /// Shows the conversation a clicked notification names.
    ///
    /// The banner may be minutes old and about a thread the current scope does
    /// not show (another mailbox picked, a search typed, archived since), so this
    /// resets to the all-mailboxes inbox and clears the search before selecting.
    /// A thread that is genuinely gone leaves the UI on the inbox rather than
    /// selecting nothing in a mystery scope.
    func revealConversation(threadID: String) async {
        // The Drafts folder occupies the SAME middle column as the conversation
        // list, so a banner clicked while it is open would select the thread
        // behind a drafts list that never went away — the reading pane would
        // change and nothing else would, with the sidebar still on Drafts.
        // How this reveal was reached is the CALLER's to say — the notification
        // router sets `.notification` before calling — so an unattributed reveal
        // is `other` like every other unlabelled navigation, rather than being
        // silently credited to a banner nobody clicked.
        let via = pendingNavigationSource ?? .other
        pendingNavigationSource = nil
        let wasShowingDrafts = isShowingDrafts
        // Silent: the view this lands on is the inbox, reported once below —
        // never a drafts→inbox→inbox trail for one click.
        showDrafts(false, silently: true)
        searchQuery = ""
        let inbox = FolderSelection(mailboxID: nil, folder: .inbox)
        if selection != inbox {
            pendingNavigationSource = via
            selection = inbox
            // The `didSet` starts the reload; awaiting it is what makes the row
            // available to select below.
            await reloadTask?.value
        } else if wasShowingDrafts || isShowingThread {
            // Already on the inbox scope, but not looking at it: the click still
            // moved the user back to the conversation list.
            recordViewShown(.inbox, via: via)
        }
        leaveThreadSilently()
        if !allConversations.contains(where: { $0.id == threadID }) {
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
                // would draw with no chip and the sender on line one — and the list
                // caches that shorter row. Mailboxes reload before conversations
                // below, so the chip is there on the row's first render.
                if let mailboxID = message.mailboxID, mailboxNames[mailboxID] == nil {
                    reloadMailboxList = true
                }
                if inScope(message) || visibleThreads.contains(message.threadID) {
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
        do {
            return try await store.hasConversation(
                threadID: threadID,
                accountID: accountID,
                mailboxID: selection.mailboxID,
                folder: selection.folder
            )
        } catch {
            logger.warning("Conversation scope check failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    private func inScope(_ message: MessageSummary) -> Bool {
        guard selection.mailboxID == nil || message.mailboxID == selection.mailboxID else { return false }
        return Self.conversationFolder(for: message.folder) == selection.folder
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
            mailboxes = loaded
            mailboxNames = Self.makeMailboxNames(loaded)
            mailboxAddresses = Dictionary(
                loaded.map { ($0.id, $0.address) }, uniquingKeysWith: { first, _ in first }
            )
            loadMailboxColorOverrides(for: loaded)
        } catch {
            logger.error("Mailbox load failed: \(error.localizedDescription, privacy: .private)")
        }
        await reloadUnreadCounts()
    }

    func reloadConversations() async {
        conversationReloadCount += 1
        // The scope is captured BEFORE the await: two selection flips in a row
        // otherwise race, and whichever store read finishes last wins — showing
        // the previous folder's rows under the current selection.
        let scope = selection
        do {
            let rows = try await store.conversations(
                accountID: accountID,
                mailboxID: scope.mailboxID,
                folder: scope.folder
            )
            guard scope == selection, !Task.isCancelled else { return }
            allConversations = rows
        } catch {
            logger.error("Conversation load failed: \(error.localizedDescription, privacy: .private)")
            guard scope == selection, !Task.isCancelled else { return }
            allConversations = []
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

    /// Inbox unread badges only — the other folders do not carry a count in the
    /// sidebar, so fetching them would be work nobody reads.
    ///
    /// Each badge is a `fetchCount` in the store. Fetching and mapping up to 100
    /// whole rows per mailbox to count them is the same query with every row
    /// materialised, and it ran on every conversation reload.
    private func reloadUnreadCounts() async {
        var counts: [FolderSelection: Int] = [:]
        for scope in unreadBadgeScopes {
            do {
                let unread = try await store.unreadCount(
                    accountID: accountID,
                    mailboxID: scope.mailboxID,
                    folder: scope.folder
                )
                if unread > 0 { counts[scope] = unread }
            } catch {
                logger.error("Unread count failed: \(error.localizedDescription, privacy: .private)")
            }
        }
        unreadCounts = counts
        // The all-mailboxes inbox count — the same number the account picker
        // shows, so the Dock badge and the switcher can never disagree.
        unreadCountDidChange?(pickerUnread(forMailbox: nil))
    }

    /// The scopes a badge is actually drawn for:
    /// - every folder of the PICKED mailbox (the one folder list the sidebar now
    ///   shows), including Starred;
    /// - the inbox of every mailbox plus the all-mailboxes inbox, which is what
    ///   the picker's own labels read.
    ///
    /// "All Mailboxes" is its own count rather than the sum of the others: the
    /// nil-mailbox listing shows every row, including any whose mailbox the
    /// picker does not list.
    private var unreadBadgeScopes: [FolderSelection] {
        var scopes = MailTheme.sidebarFolders.map {
            FolderSelection(mailboxID: selection.mailboxID, folder: $0)
        }
        scopes.append(FolderSelection(mailboxID: nil, folder: .inbox))
        scopes.append(contentsOf: mailboxes.map { FolderSelection(mailboxID: $0.id, folder: .inbox) })
        // The picked mailbox is in both halves; counting it twice is one wasted
        // fetchCount per reload.
        var seen: Set<FolderSelection> = []
        return scopes.filter { seen.insert($0).inserted }
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

    /// Every address this account owns, across all its mailboxes. Reply-all
    /// subtracts these, so passing an empty list would CC the user themselves.
    var ownAddresses: [String] {
        EmailAddress.dedupe(mailboxes.flatMap { [$0.address] + $0.addresses.map(\.address) })
    }

    /// The address a message from `mailboxID` should be sent from: the mailbox's
    /// primary send-enabled address, falling back to its main address.
    func sendAddress(forMailbox mailboxID: String?) -> String {
        guard let mailbox = mailboxes.first(where: { $0.id == mailboxID }) ?? mailboxes.first else { return "" }
        return mailbox.sendableAddresses.first?.address ?? mailbox.address
    }

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
                storedDraft: stored
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
        let mailboxID = message?.summary.mailboxID ?? request.mailboxID
        return ComposeContext(
            id: request.id,
            kind: request.kind,
            mailboxID: mailboxID,
            fromAddress: sendAddress(forMailbox: mailboxID),
            ownAddresses: ownAddresses,
            message: message
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
