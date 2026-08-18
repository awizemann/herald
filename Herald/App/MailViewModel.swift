import Foundation
import HeraldKit
import OSLog

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "MailViewModel")

/// The sync loop, as the view-model needs it. `nonisolated` so ``SyncEngine``
/// (an actor) can conform.
nonisolated protocol MailSyncing: Sendable {
    func refreshNow() async
    func setCadence(_ cadence: SyncCadence) async
}

extension SyncEngine: MailSyncing {}

/// A request to open the composer. P0.5 owns the composer itself; this is the
/// hook it plugs into, so ⌘R already has somewhere to land.
nonisolated struct ComposeRequest: Sendable, Hashable, Identifiable {
    enum Kind: Sendable, Hashable { case reply, replyAll, forward, new }

    let id = UUID()
    var kind: Kind
    var messageID: String?
    var mailboxID: String?
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

    // MARK: Dependencies

    let accountID: String
    let accountLabel: String
    let api: any MailAPIClient
    private let store: MailStore
    let actions: MailActionService
    private let sync: (any MailSyncing)?
    private let events: AsyncStream<SyncEvent>
    /// How long a message must stay selected before it is marked read. Injected
    /// so tests can drive both sides of the rule without real waiting.
    private let markReadDelay: Duration
    /// Where per-mailbox colour overrides live. Injected so a test drives a
    /// throwaway suite instead of the user's real preferences.
    private let defaults: UserDefaults

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
            guard selection != oldValue else { return }
            selectedThreadID = nil
            // The folder is half of the presentation rule, so the visible list is
            // wrong until it is recomputed — don't wait for the store round trip.
            refilter()
            // Cancel first: replacing a running task leaves the older, slower
            // reload alive to finish last and overwrite the newer scope's rows.
            reloadTask?.cancel()
            reloadTask = Task { await reloadConversations() }
        }
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
            refilter()
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

    /// Row id → the lowercased text search matches against, built once per load
    /// instead of once per row per keystroke.
    @ObservationIgnored private var searchIndex: [String: String] = [:]

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
            isShowingThread = drillsOnSelection ? (threadID.map(isMultiMessage) ?? false) : false
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
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
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
    }

    // MARK: - Derived state

    /// Recomputes ``presentedConversations``. The ONLY writer of it, called from
    /// the `didSet` of each of the three inputs the filter depends on.
    private func refilter() {
        filterCount += 1
        let folder = selection.folder
        let inScope = allConversations.filter { Self.belongs($0, to: folder) }
        guard !searchQuery.isEmpty else {
            presentedConversations = inScope
            return
        }
        let needle = searchQuery.lowercased()
        presentedConversations = inScope.filter { searchIndex[$0.id]?.contains(needle) ?? false }
    }

    /// The searchable text of each row, lowercased once at load time.
    private nonisolated static func makeSearchIndex(
        _ rows: [ConversationSummary]
    ) -> [String: String] {
        var index: [String: String] = [:]
        index.reserveCapacity(rows.count)
        for row in rows {
            index[row.id] = "\(row.latest.subject)\n\(row.latest.fromAddress)\n\(row.latest.snippet)"
                .lowercased()
        }
        return index
    }

    var selectedConversation: ConversationSummary? {
        guard let selectedThreadID else { return nil }
        return allConversations.first { $0.id == selectedThreadID }
    }

    var selectedMessage: MessageSummary? {
        guard let selectedMessageID else { return nil }
        return threadMessages.first { $0.id == selectedMessageID }
    }

    /// Whether a thread is worth drilling into. Resolved against
    /// ``allConversations`` (the unfiltered source), never the presented list: a
    /// search that hides the row must not change what selecting it does.
    private func isMultiMessage(_ threadID: String) -> Bool {
        (allConversations.first { $0.id == threadID }?.messageCount ?? 1) > 1
    }

    /// The back chevron / ⎋ / ⌘[: leave the thread, keep the row selected.
    func exitThread() {
        isShowingThread = false
    }

    /// Drills into the selected conversation — the ⏎ and chevron path. A
    /// single-message conversation has nothing to drill into and is a no-op:
    /// it is already fully shown in the reading pane.
    func openSelectedThread() {
        guard let selectedThreadID, isMultiMessage(selectedThreadID) else { return }
        isShowingThread = true
    }

    /// Drills into a specific row — the mouse-click path, where the click both
    /// selects and opens. Selecting first is deliberate: it is what loads the
    /// thread, and re-clicking the row that is already selected must still open
    /// it (the selection binding would report no change at all).
    func openThread(_ threadID: String) {
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
    }

    /// Set by ``refresh()``, consumed by the next `.finished` event.
    @ObservationIgnored private var reloadsWhenPassFinishes = false

    /// The Refresh button (and ⌘⇧K, and the post-action refresh).
    ///
    /// A pass only reports what CHANGED, and a pass that changed nothing the
    /// current scope's rows are keyed by used to leave the list exactly as it
    /// was — which is what made "Refresh doesn't show the mail I just deleted,
    /// but leaving the folder and coming back does" (issue #6). Whatever the
    /// ChangeSets say, an explicit refresh reloads the presented scope once the
    /// pass finishes, because that is what pressing Refresh means.
    func refresh() async {
        reloadsWhenPassFinishes = true
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
            case .finished:
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
                await apply(changes)
            case .failed(let error):
                if Self.requiresReauthentication(error) {
                    status = .needsReauth
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
        if let selectedThreadID, !allConversations.contains(where: { $0.id == selectedThreadID }) {
            self.selectedThreadID = nil
        }
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
            let messages = try await store.messages(accountID: accountID, threadID: threadID)
            guard !Task.isCancelled, selectedThreadID == threadID else { return }
            threadMessages = messages
            if selectedMessageID == nil || !messages.contains(where: { $0.id == selectedMessageID }) {
                // Newest first, so the newest is the head of the list.
                selectedMessageID = messages.first?.id
            }
        } catch {
            logger.error("Thread load failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Message detail and body

    private func loadDetail(_ messageID: String) async {
        isLoadingBody = true
        // Only the load for the CURRENT selection may clear the flag: a superseded
        // load finishing late would otherwise hide the spinner for the new one.
        defer { if selectedMessageID == messageID { isLoadingBody = false } }
        do {
            // Attachments and the full recipient list are not cached, so the
            // single-message route is the source here (never a list route).
            let loaded = try await api.message(id: messageID)
            guard !Task.isCancelled, selectedMessageID == messageID else { return }
            detail = loaded
            await loadBody(for: loaded, allowRemote: false)
        } catch {
            logger.warning("Message detail failed: \(error.localizedDescription, privacy: .private)")
            guard selectedMessageID == messageID else { return }
            actionError = error.localizedDescription
        }
    }

    private func loadBody(for detail: MessageDetail, allowRemote: Bool) async {
        let messageID = detail.id
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
            await cacheBody(messageID: messageID, text: text, html: nil)
            return
        }

        do {
            let payload = try await api.messageHTML(id: messageID, loadRemoteImages: allowRemote)
            guard !Task.isCancelled, selectedMessageID == messageID else { return }
            let inline = await inlineImages(for: detail)
            guard !Task.isCancelled, selectedMessageID == messageID else { return }
            let raw = payload.html
            // Substitution walks the whole body; never on the main actor.
            let substituted = await Task.detached(priority: .userInitiated) { @Sendable in
                Self.document(
                    wrapping: Self.substituteInlineImages(in: raw, with: inline),
                    title: title,
                    allowsRemote: allowRemote
                )
            }.value
            guard selectedMessageID == messageID else { return }
            body = RenderedBody(
                messageID: messageID,
                html: substituted,
                blocksRemote: !allowRemote,
                offersRemoteConsent: payload.needsRemoteMediaConsent && !allowRemote
            )
            await cacheBody(messageID: messageID, text: detail.textBody, html: payload.html)
        } catch {
            logger.warning("Message HTML failed: \(error.localizedDescription, privacy: .private)")
            guard selectedMessageID == messageID else { return }
            // Fall back to the cached copy so an offline read still shows something.
            if let cached = try? await store.cachedBody(messageID: messageID, accountID: accountID), let html = cached.html {
                let wrapped = await Task.detached(priority: .userInitiated) { @Sendable in
                    Self.document(wrapping: html, title: title)
                }.value
                guard selectedMessageID == messageID else { return }
                body = RenderedBody(messageID: messageID, html: wrapped, blocksRemote: true, offersRemoteConsent: false)
            } else {
                actionError = error.localizedDescription
            }
        }
    }

    private func cacheBody(messageID: String, text: String, html: String?) async {
        do {
            try await store.storeBody(messageID: messageID, accountID: accountID, textBody: text, html: html)
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
            for await entry in group {
                guard let entry else { continue }
                result[entry.0] = entry.1
            }
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
