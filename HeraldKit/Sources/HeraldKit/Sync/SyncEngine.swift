import Foundation
import OSLog

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "SyncEngine")

/// What the sync loop tells the UI. `.changed` is only emitted when something
/// actually changed, so an unchanged poll never invalidates a view.
public nonisolated enum SyncEvent: Sendable {
    case began
    case changed(ChangeSet)
    /// The DRAFTS table changed. Its own case, not folded into `.changed`,
    /// because drafts are not messages: the ids in a ``ChangeSet`` are resolved
    /// against the message cache by the view-model, and a draft id would resolve
    /// to nothing and be mistaken for a brand-new mailbox.
    case draftsChanged(ChangeSet)
    case finished
    case failed(any Error)
}

/// One folder the engine keeps in sync: a message-listing folder, a
/// conversation-listing folder, or both.
///
/// The two surfaces do not line up. `drafts` has no conversation counterpart
/// (the conversation surface swaps `drafts` for `starred`), and `starred` is the
/// mirror image: a real server-side `ConversationFolder` with NO message folder
/// behind it — starred messages keep living in inbox/sent/archived and the
/// starred list is derived from `starredAt`. Both halves are therefore optional,
/// and a pass walks whichever ones the folder actually has.
public nonisolated struct SyncFolder: Sendable, Hashable {
    public let message: MailFolder?
    public let conversation: ConversationFolder?

    public init(message: MailFolder?, conversation: ConversationFolder?) {
        self.message = message
        self.conversation = conversation
    }

    public static let inbox = SyncFolder(message: .inbox, conversation: .inbox)
    public static let sent = SyncFolder(message: .sent, conversation: .sent)
    public static let archived = SyncFolder(message: .archived, conversation: .archived)
    public static let trash = SyncFolder(message: .trash, conversation: .trash)
    public static let drafts = SyncFolder(message: .drafts, conversation: nil)
    public static let catchall = SyncFolder(message: .catchall, conversation: .catchall)
    /// Conversation-only: `GET /messages?folder=starred` does not exist.
    public static let starred = SyncFolder(message: nil, conversation: .starred)
}

/// Which folders one pass covers.
public nonisolated struct SyncScope: Sendable, Hashable {
    public var folders: [SyncFolder]

    public init(folders: [SyncFolder]) { self.folders = folders }

    /// The folders the sidebar shows by default, in sidebar order.
    public static let `default` = SyncScope(folders: [.inbox, .starred, .sent, .archived, .trash])
    /// Adds the optional surfaces.
    public static let complete = SyncScope(
        folders: [.inbox, .starred, .sent, .archived, .trash, .drafts, .catchall]
    )
}

/// Polling cadence. There is no push (the server's only push is browser Web
/// Push), so the client polls — cheaply in journal mode, by re-listing on an
/// older server: 15s while a window is key, 60s when idle.
public nonisolated enum SyncCadence: Sendable, Hashable {
    case active
    case idle

    var interval: Duration {
        switch self {
        case .active: .seconds(15)
        case .idle: .seconds(60)
        }
    }
}

/// Owns the per-account poll loop: list → diff → store → publish.
///
/// The loop lives inside this actor, so its `Task.sleep` is never on the main
/// actor; `refreshNow()` interrupts the wait through a continuation rather than
/// spawning a competing pass.
public actor SyncEngine {
    /// Hard stop on the conversation page-walk. A server that keeps handing back
    /// a `nextCursor` must not spin the loop forever.
    public static let defaultMaxConversationPages = 20
    /// Same idea for the message page-walk: 50 × 100 rows per folder is far more
    /// than any cache needs and bounds a server that keeps handing back cursors.
    public static let defaultMaxMessagePages = 50

    /// How rarely the drafts list is re-polled. Drafts are the one surface with
    /// no delta at all — `GET /drafts` is a whole-list read with no pagination
    /// and no journal entry — so it is deliberately NOT on the 15s message
    /// cadence: a folder the user visits occasionally does not justify a third
    /// request on every active-cadence tick. Local edits write straight through
    /// to the cache (`MailStore.storeLocalDraft`), so the user's OWN drafts are
    /// never waiting on this; it only catches drafts written elsewhere.
    public static let defaultDraftPollInterval: Duration = .seconds(60)

    private let api: any MailAPIClient
    private let store: MailStore
    private let scope: SyncScope
    private let maxConversationPages: Int
    private let maxMessagePages: Int
    private let draftPollInterval: Duration

    /// When the drafts list was last read. `nil` means "never", which is what
    /// makes the first pass of a session always poll them.
    private var lastDraftPoll: ContinuousClock.Instant?

    private let eventStream: AsyncStream<SyncEvent>
    private let eventContinuation: AsyncStream<SyncEvent>.Continuation

    private var accountID: String?
    private var loopTask: Task<Void, Never>?
    private var cadence: SyncCadence = .active
    private var consecutiveFailures = 0

    /// Coalescing state: a refresh asked for while a pass is in flight becomes
    /// exactly ONE more pass, not one per request.
    private var isSyncing = false
    private var refreshPending = false

    /// Bumped by `start()` and `stop()`. Only ever ONE pass is in flight (that is
    /// what the coalescing above guarantees), so a pass records the generation it
    /// began under and every step compares it to the current one: the moment they
    /// diverge the pass unwinds instead of writing more rows into a store the app
    /// is about to purge.
    private var passGeneration = 0
    private var runningPassGeneration = 0

    /// Wait state: the loop parks on `wakeContinuation` until either the cadence
    /// timer or `refreshNow()`/`stop()` resumes it.
    private var wakeContinuation: CheckedContinuation<Void, Never>?
    private var wakeSignalled = false
    /// Bumped on every wait. A cadence timer carries the generation it was armed
    /// for, so a timer that outlived its wait (the loop was woken by
    /// `refreshNow()`) cannot latch `wakeSignalled` and make the NEXT wait return
    /// instantly — which is a free extra pass, and at speed a spin loop.
    private var waitGeneration = 0

    public init(
        api: any MailAPIClient,
        store: MailStore,
        scope: SyncScope = .default,
        maxConversationPages: Int = SyncEngine.defaultMaxConversationPages,
        maxMessagePages: Int = SyncEngine.defaultMaxMessagePages,
        draftPollInterval: Duration = SyncEngine.defaultDraftPollInterval
    ) {
        self.api = api
        self.store = store
        self.scope = scope
        self.maxConversationPages = max(1, maxConversationPages)
        self.maxMessagePages = max(1, maxMessagePages)
        self.draftPollInterval = draftPollInterval
        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .unbounded)
        self.eventStream = stream
        self.eventContinuation = continuation
    }

    deinit {
        eventContinuation.finish()
    }

    /// The event feed. Single-consumer, as `AsyncStream` always is — the
    /// view-model owns it.
    public nonisolated var events: AsyncStream<SyncEvent> { eventStream }

    // MARK: - Lifecycle

    /// Starts (or restarts) the loop for an account. The first pass runs
    /// immediately; subsequent passes wait for the cadence or a refresh.
    public func start(accountID: String) {
        guard self.accountID != accountID || loopTask == nil else { return }
        stop()
        self.accountID = accountID
        consecutiveFailures = 0
        wakeSignalled = false
        // A different account (or a restarted engine) has never polled ITS drafts.
        lastDraftPoll = nil
        loopTask = Task { [weak self] in
            await self?.runLoop(accountID: accountID)
        }
    }

    public func stop() {
        passGeneration &+= 1
        loopTask?.cancel()
        loopTask = nil
        refreshPending = false
        signalWake()
    }

    /// `stop()` only ASKS: the in-flight pass is still parked on a URLSession call
    /// and will keep going — and writing — for as long as that call takes. A
    /// caller that is about to `deleteAll` the cache (sign-out, account switch)
    /// must wait for the loop to actually unwind, or the purge races the pass and
    /// the next account starts on the previous one's rows.
    public func stopAndWait() async {
        let task = loopTask
        stop()
        await task?.value
    }

    /// Asks for a pass now. Coalesced: if a pass is already running this marks
    /// the loop dirty so exactly one more pass follows it.
    public func refreshNow() {
        guard loopTask != nil else { return }
        if isSyncing {
            refreshPending = true
        } else {
            signalWake()
        }
    }

    /// Asks for a pass that also re-reads the drafts list, whatever the draft
    /// interval says.
    ///
    /// Separate from ``refreshNow()`` on purpose: that one also fires after every
    /// archive and every trash, and putting a whole-list `GET /drafts` behind each
    /// triage keystroke is exactly the cost the interval exists to avoid. This is
    /// for the moments the user is actually asking about drafts — opening the
    /// Drafts folder, or pressing Refresh while looking at it.
    public func refreshDraftsNow() {
        lastDraftPoll = nil
        refreshNow()
    }

    /// Switches the poll interval. Takes effect on the next wait, and wakes the
    /// loop when speeding up so the change is not delayed by a full idle period.
    public func setCadence(_ cadence: SyncCadence) {
        guard cadence != self.cadence else { return }
        self.cadence = cadence
        if cadence == .active { signalWake() }
    }

    // MARK: - Loop

    private func runLoop(accountID: String) async {
        while !Task.isCancelled {
            await runPass(accountID: accountID)
            guard loopTask != nil, !Task.isCancelled else { break }

            if refreshPending {
                // A refresh arrived mid-pass: run once more, immediately.
                refreshPending = false
                continue
            }
            await waitForNextTick()
        }
    }

    /// Parks the loop until the cadence timer fires or someone signals a wake.
    private func waitForNextTick() async {
        waitGeneration &+= 1
        let generation = waitGeneration
        let interval = backoffInterval ?? cadence.interval
        let timer = Task { [weak self] in
            // A cancelled timer must NOT signal: swallowing the cancellation and
            // waking anyway leaves `wakeSignalled` latched, and the next wait
            // returns instantly — a spin loop that polls the server flat out.
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            await self?.timerFired(generation: generation)
        }
        defer { timer.cancel() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if wakeSignalled {
                wakeSignalled = false
                continuation.resume()
            } else {
                wakeContinuation = continuation
            }
        }
    }

    /// The cadence timer's only entry point. A stale generation, or a wait that is
    /// no longer parked, means this timer belongs to a wait that already ended:
    /// it must do nothing at all, not even latch.
    func timerFired(generation: Int) {
        guard generation == waitGeneration, wakeContinuation != nil else { return }
        signalWake()
    }

    /// Whether the loop is currently parked on a cadence wait. Test seam: it is
    /// what makes "a stale timer did NOT wake the loop" assertable.
    var isParkedOnCadenceWait: Bool { wakeContinuation != nil }

    /// Test seam: a cancelled pass must not count as a failure (which would put
    /// the loop into exponential backoff for something the user did).
    var consecutiveFailureCount: Int { consecutiveFailures }

    private func signalWake() {
        if let continuation = wakeContinuation {
            wakeContinuation = nil
            continuation.resume()
        } else {
            wakeSignalled = true
        }
    }

    /// Exponential backoff after a failed pass: 2x the cadence, doubling, capped
    /// at 5 minutes. `nil` while healthy.
    private var backoffInterval: Duration? {
        guard consecutiveFailures > 0 else { return nil }
        let base = cadence.interval.components.seconds
        let multiplier = Int64(1) << Int64(min(consecutiveFailures, 8))
        let seconds = min(base.multipliedReportingOverflow(by: multiplier).partialValue, 300)
        return .seconds(max(seconds, base))
    }

    // MARK: - One pass

    /// Every step of a pass funnels through here before it touches the store.
    /// `Task.isCancelled` alone is not enough: it is observed only where the code
    /// looks, and `stop()` returning does not mean the pass has noticed yet.
    private func checkPassIsCurrent() throws {
        try Task.checkCancellation()
        guard runningPassGeneration == passGeneration else { throw CancellationError() }
    }

    private func runPass(accountID: String) async {
        isSyncing = true
        runningPassGeneration = passGeneration
        defer { isSyncing = false }
        emit(.began)
        do {
            let changes = try await syncEverything(accountID: accountID)
            try checkPassIsCurrent()
            consecutiveFailures = 0
            if !changes.isEmpty { emit(.changed(changes)) }
            // Deliberately AFTER the mail sync and outside its result: drafts are
            // a separate surface on a separate cadence, and their own failure
            // mode must not decide whether the mail pass succeeded.
            await syncDraftsIfDue(accountID: accountID)
            emit(.finished)
        } catch let error as MailAPIError where error == .unauthorized {
            // Nothing the loop can do: the UI has to re-authenticate. Stop
            // rather than hammer the server with doomed requests.
            logger.warning("Sync stopped: token rejected, re-authentication required")
            emit(.failed(error))
            stop()
        } catch is CancellationError {
            logger.warning("Sync pass cancelled")
        } catch where Task.isCancelled || Self.isCancellation(error) {
            // A pass torn down by `stop()` is not a server failure: reporting it
            // as `.failed` shows the user a sync error for their own sign-out or
            // account switch, and bumping the backoff would slow the NEXT account
            // down for minutes.
            logger.warning("Sync pass cancelled")
        } catch {
            consecutiveFailures += 1
            logger.warning(
                "Sync pass \(self.consecutiveFailures, privacy: .public) failed (\((error as? MailAPIError)?.logCode ?? String(describing: type(of: error)), privacy: .public)): \(error.localizedDescription, privacy: .private)"
            )
            emit(.failed(error))
        }
    }

    /// URLSession reports a cancelled request as a transport error, not as
    /// `CancellationError`, so the typed form has to be recognized too.
    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        guard let apiError = error as? MailAPIError, case .transport(let failure) = apiError else { return false }
        return failure.domain == URLError.errorDomain && failure.code == URLError.cancelled.rawValue
    }

    // MARK: - Drafts

    /// Accounts whose token cannot read `GET /drafts` at all. The route needs the
    /// `mail:send` scope, so an account consented without it answers 401/403 on
    /// EVERY pass — and folding that into the pass result would park a perfectly
    /// healthy mailbox in exponential backoff behind a banner, forever. Recorded
    /// once and skipped for the engine's lifetime; restarting the engine (a
    /// re-consent, an app activation) probes again.
    private var draftlessAccounts: Set<String> = []

    /// Polls and reconciles the drafts list when its own interval has elapsed.
    ///
    /// Never throws: a drafts failure is not a sync failure (see above). It also
    /// never advances `lastDraftPoll` on failure, so a transient error is retried
    /// on the next pass rather than sat out for the whole interval.
    private func syncDraftsIfDue(accountID: String) async {
        guard !draftlessAccounts.contains(accountID), isDraftPollDue else { return }
        do {
            let listed = try await api.listDrafts()
            try checkPassIsCurrent()
            let changes = try await store.reconcileDrafts(listed, accountID: accountID)
            lastDraftPoll = .now
            if !changes.isEmpty { emit(.draftsChanged(changes)) }
        } catch let error as MailAPIError where error == .unauthorized || Self.isScopeRefusal(error) {
            logger.warning("Drafts unavailable for this account (\(error.logCode, privacy: .public)); not polling them again this session")
            draftlessAccounts.insert(accountID)
        } catch is CancellationError {
            // Torn down by stop(); nothing to report and nothing to record.
        } catch {
            logger.warning("Draft poll failed: \(((error as? MailAPIError)?.logCode ?? "unknown"), privacy: .public)")
        }
    }

    private var isDraftPollDue: Bool {
        guard let lastDraftPoll else { return true }
        return lastDraftPoll.duration(to: .now) >= draftPollInterval
    }

    nonisolated static func isScopeRefusal(_ error: MailAPIError) -> Bool {
        if case .insufficientScope = error { return true }
        if case .server(let code, _) = error { return code == "http_403" }
        return false
    }

    /// Test seam: how many passes actually reached `GET /drafts`. It is what makes
    /// "the second pass did NOT re-poll drafts" assertable without a clock.
    var lastDraftPollInstant: ContinuousClock.Instant? { lastDraftPoll }

    // MARK: - Mode selection

    /// Thrown internally when `GET /changes` answers 404 — the route does not
    /// exist on this server. Kept private so a 404 from any OTHER call (which is
    /// a real error) can never be mistaken for "no journal".
    private struct ChangeFeedUnsupported: Error {}

    /// Feature detection, in one place:
    ///
    /// - `/changes` answering **404** means the server predates the journal. The
    ///   account is marked legacy for the lifetime of THIS engine (one app
    ///   activation) and every later pass goes straight to the full-listing path;
    ///   restarting the engine re-probes, which is what makes a server upgrade
    ///   take effect without quitting Herald.
    /// - Any successful `/changes` response means journal mode.
    /// - Pagination is detected independently, from the `Link` header: the first
    ///   `nextCursor` seen for an account proves the server paginates, which is
    ///   what retires the 100-row tombstone guard.
    private var legacyAccounts: Set<String> = []
    private var paginatingAccounts: Set<String> = []

    /// A 404 means "no such route" ONLY on the cursor-less probe. With a cursor
    /// in hand the account has already answered `/changes` successfully at least
    /// once, so a 404 there is a transient server fault (a bad deploy, a proxy);
    /// treating it as "no journal" silently drops the account into full re-listing
    /// for the rest of the session and re-lists every mailbox every 15 seconds.
    private func fetchChanges(cursor: String?) async throws -> ChangePage {
        do {
            return try await api.changes(cursor: cursor, limit: Self.changePageLimit)
        } catch let error as MailAPIError where error == .notFound {
            guard cursor == nil else { throw error }
            throw ChangeFeedUnsupported()
        }
    }

    private func syncEverything(accountID: String) async throws -> ChangeSet {
        guard !legacyAccounts.contains(accountID) else {
            return try await legacySync(accountID: accountID)
        }
        do {
            return try await journalSync(accountID: accountID)
        } catch is ChangeFeedUnsupported {
            logger.warning("Server has no /changes route; falling back to full-listing sync for this session")
            legacyAccounts.insert(accountID)
            return try await legacySync(accountID: accountID)
        }
    }

    // MARK: - Legacy mode (server without /changes)

    /// Exactly the pre-journal behaviour: re-list every mailbox × folder and diff.
    private func legacySync(accountID: String) async throws -> ChangeSet {
        var changes = ChangeSet()
        let mailboxes = try await api.listMailboxes()
        try checkPassIsCurrent()
        changes.formUnion(try await store.upsertMailboxes(mailboxes, accountID: accountID))

        for mailbox in mailboxes {
            changes.formUnion(try await syncMailbox(accountID: accountID, mailboxID: mailbox.id))
        }
        return changes
    }

    /// Every folder in scope for one mailbox: conversations, then messages.
    private func syncMailbox(accountID: String, mailboxID: String) async throws -> ChangeSet {
        var changes = ChangeSet()
        for folder in scope.folders {
            try checkPassIsCurrent()
            if let conversationFolder = folder.conversation {
                changes.formUnion(
                    try await syncConversations(accountID: accountID, mailboxID: mailboxID, folder: conversationFolder)
                )
            }
            if let messageFolder = folder.message {
                changes.formUnion(
                    try await syncMessages(accountID: accountID, mailboxID: mailboxID, folder: messageFolder)
                )
            }
        }
        return changes
    }

    // MARK: - Journal mode (server with /changes)

    private func journalSync(accountID: String) async throws -> ChangeSet {
        let checkpoint = try await store.syncCheckpoint(accountID: accountID)
        guard let checkpoint, checkpoint.isBootstrapped, let cursor = checkpoint.changeCursor else {
            return try await bootstrap(accountID: accountID)
        }
        do {
            return try await steadyState(accountID: accountID, cursor: cursor, bootstrappedAt: checkpoint.bootstrappedAt)
        } catch let error as MailAPIError where error == .cursorExpired {
            logger.warning("Change cursor expired; discarding the checkpoint and re-bootstrapping")
            try await store.clearSyncCheckpoint(accountID: accountID)
            return try await bootstrap(accountID: accountID)
        }
    }

    /// Checkpoint FIRST, then the full listing, then the changes that landed
    /// while the listing ran. Taking the checkpoint afterwards would silently
    /// drop every change made during the listing.
    private func bootstrap(accountID: String) async throws -> ChangeSet {
        let checkpoint = try await fetchChanges(cursor: nil)
        var changes = ChangeSet()
        let mailboxes = try await api.listMailboxes()
        let cached = Set(try await store.mailboxes(accountID: accountID).map(\.id))
        changes.formUnion(
            try await listMailboxes(mailboxes, accountID: accountID, cached: cached, listKnown: true)
        )
        // The listing is complete, so the checkpoint it was taken against is
        // durable NOW. Persisting it only after the catch-up meant one flaky
        // `/changes` read threw the whole listing away and re-listed every
        // mailbox on the next pass.
        let bootstrappedAt = Date()
        try checkPassIsCurrent()
        try await store.setSyncCheckpoint(
            SyncCheckpoint(changeCursor: checkpoint.nextCursor, bootstrappedAt: bootstrappedAt),
            accountID: accountID
        )
        changes.formUnion(
            try await consumeChanges(
                accountID: accountID,
                from: checkpoint.nextCursor,
                bootstrappedAt: bootstrappedAt
            )
        )
        return changes
    }

    private func steadyState(accountID: String, cursor: String, bootstrappedAt: Date?) async throws -> ChangeSet {
        var changes = ChangeSet()
        let mailboxes = try await api.listMailboxes()
        let current = Set(mailboxes.map(\.id))
        let cached = Set(try await store.mailboxes(accountID: accountID).map(\.id))

        // A mailbox the server stopped returning is one we can no longer read:
        // its cached mail must go, and the journal will never mention it again.
        for gone in cached.subtracting(current).sorted() {
            logger.warning("Mailbox \(gone, privacy: .public) is no longer readable; purging its cache")
            try checkPassIsCurrent()
            changes.formUnion(try await store.purgeMailbox(mailboxID: gone, accountID: accountID))
        }

        changes.formUnion(
            try await listMailboxes(mailboxes, accountID: accountID, cached: cached, listKnown: false)
        )

        changes.formUnion(
            try await consumeChanges(accountID: accountID, from: cursor, bootstrappedAt: bootstrappedAt ?? Date())
        )
        return changes
    }

    /// Writes the mailbox rows, with ONE ordering rule that matters: a mailbox
    /// the cache has never seen gets its row only AFTER its listing succeeds.
    ///
    /// Persisting the row first makes the mailbox "known" — and a listing that
    /// then throws leaves a mailbox that no later pass will ever bootstrap
    /// (steady state lists only mailboxes it considers new) and that the journal
    /// only ever tells us deltas about. The user sees a permanently empty
    /// mailbox. Rows the cache already has are written up front, since their
    /// listing is not what makes them trustworthy.
    private func listMailboxes(
        _ mailboxes: [Mailbox],
        accountID: String,
        cached: Set<String>,
        listKnown: Bool
    ) async throws -> ChangeSet {
        var changes = ChangeSet()
        let known = mailboxes.filter { cached.contains($0.id) }
        if !known.isEmpty {
            try checkPassIsCurrent()
            changes.formUnion(try await store.upsertMailboxes(known, accountID: accountID))
        }
        for mailbox in mailboxes.sorted(by: { $0.id < $1.id }) {
            let isNew = !cached.contains(mailbox.id)
            guard isNew || listKnown else { continue }
            changes.formUnion(try await syncMailbox(accountID: accountID, mailboxID: mailbox.id))
            guard isNew else { continue }
            try checkPassIsCurrent()
            changes.formUnion(try await store.upsertMailboxes([mailbox], accountID: accountID))
        }
        return changes
    }

    /// Walks the journal from `cursor` until `hasMore == false`, persisting the
    /// checkpoint after EACH applied page: a crash (or a thrown page) mid-cycle
    /// resumes where it stopped instead of replaying — or worse, re-listing.
    private func consumeChanges(accountID: String, from cursor: String, bootstrappedAt: Date) async throws -> ChangeSet {
        var changes = ChangeSet()
        var next = cursor

        while true {
            try checkPassIsCurrent()
            let page = try await fetchChanges(cursor: next)
            var touched: Set<ConversationScope> = []
            changes.formUnion(try await apply(page.changes, accountID: accountID, touched: &touched))

            // Conversation rows are derived, so only the scopes this page
            // actually touched are re-listed — a quiet pass costs zero
            // conversation calls. It happens BEFORE the cursor moves: a cursor
            // persisted while the derived rows were still stale is a cache that
            // never heals, because the page that would have fixed it is now
            // behind the cursor and will never be read again.
            for scope in touched.sorted(by: {
                ($0.mailboxID ?? "", $0.folder.rawValue) < ($1.mailboxID ?? "", $1.folder.rawValue)
            }) {
                changes.formUnion(
                    try await syncConversations(accountID: accountID, mailboxID: scope.mailboxID, folder: scope.folder)
                )
            }

            next = page.nextCursor
            try checkPassIsCurrent()
            try await store.setSyncCheckpoint(
                SyncCheckpoint(changeCursor: next, bootstrappedAt: bootstrappedAt),
                accountID: accountID
            )
            guard page.hasMore else { break }
        }
        return changes
    }

    /// One (mailbox, conversation folder) listing the journal made stale.
    private nonisolated struct ConversationScope: Sendable, Hashable {
        let mailboxID: String?
        let folder: ConversationFolder
    }

    /// Applies one page IN JOURNAL ORDER.
    ///
    /// Partitioning the page into "all upserts, then all deletes" reorders
    /// history, and both orders come off the wire: `[delete m1, upsert m1]` (a
    /// message deleted and re-delivered) ended with m1 ABSENT, and the general
    /// case is that the last word in the page must be the one that wins. The
    /// journal's order IS the truth, so only ADJACENT upserts are batched — which
    /// is all the batching change detection ever needed.
    private func apply(
        _ changes: [MessageChange],
        accountID: String,
        touched: inout Set<ConversationScope>
    ) async throws -> ChangeSet {
        var result = ChangeSet()
        var batch: [MessageSummary] = []

        for change in changes {
            switch change {
            case .upsert(let summary):
                batch.append(summary)
            case .delete(let messageID, let mailboxID):
                result.formUnion(try await flush(&batch, accountID: accountID, touched: &touched))
                try checkPassIsCurrent()
                let deletion = try await store.deleteMessage(id: messageID, accountID: accountID)
                result.formUnion(deletion.changes)
                touched.formUnion(
                    conversationScopes(mailboxID: deletion.mailboxID ?? mailboxID, folder: deletion.folder)
                )
            }
        }
        result.formUnion(try await flush(&batch, accountID: accountID, touched: &touched))
        return result
    }

    /// Writes a run of adjacent upserts and records every conversation listing
    /// they made stale — including, for a message that MOVED, the listing it
    /// moved OUT of. Refreshing only the destination leaves the source list
    /// showing a thread that is no longer in it until something else touches it.
    private func flush(
        _ batch: inout [MessageSummary],
        accountID: String,
        touched: inout Set<ConversationScope>
    ) async throws -> ChangeSet {
        guard !batch.isEmpty else { return ChangeSet() }
        let upserts = batch
        batch.removeAll(keepingCapacity: true)
        try checkPassIsCurrent()
        let result = try await store.applyMessageUpserts(upserts, accountID: accountID)
        for summary in upserts {
            touched.formUnion(conversationScopes(mailboxID: summary.mailboxID, folder: summary.folder))
            guard let previous = result.previousScopes[summary.id],
                  previous.mailboxID != summary.mailboxID || previous.folder != summary.folder
            else { continue }
            touched.formUnion(conversationScopes(mailboxID: previous.mailboxID, folder: previous.folder))
        }
        return result.changes
    }

    /// The conversation listings one message change can affect.
    ///
    /// `folder == nil` (a tombstone for a message we never cached) means we do
    /// not know which listing held it, so every folder in scope is refreshed.
    /// `starred` is always included when it is in scope: starring never changes
    /// the message folder, so nothing else would reveal it.
    private func conversationScopes(mailboxID: String?, folder: MailFolder?) -> Set<ConversationScope> {
        var scopes: Set<ConversationScope> = []
        for syncFolder in scope.folders {
            guard let conversationFolder = syncFolder.conversation else { continue }
            if conversationFolder == .starred || folder == nil || syncFolder.message == folder {
                scopes.insert(ConversationScope(mailboxID: mailboxID, folder: conversationFolder))
            }
        }
        return scopes
    }

    /// Page-walks a folder's conversations until `nextCursor` is nil or the cap
    /// is hit, then tombstones whatever the server stopped returning.
    private func syncConversations(
        accountID: String,
        mailboxID: String?,
        folder: ConversationFolder
    ) async throws -> ChangeSet {
        var changes = ChangeSet()
        var seen: Set<String> = []
        var cursor: String?
        var pages = 0
        var reachedEnd = false

        while pages < maxConversationPages {
            try checkPassIsCurrent()
            let page = try await api.listConversations(
                folder: folder,
                mailboxID: mailboxID,
                search: nil,
                cursor: cursor
            )
            pages += 1
            seen.formUnion(page.conversations.map(\.id))
            changes.formUnion(
                try await store.upsertConversations(
                    page.conversations,
                    accountID: accountID,
                    mailboxID: mailboxID,
                    folder: folder
                )
            )
            guard let next = page.nextCursor else {
                reachedEnd = true
                break
            }
            cursor = next
        }

        if !reachedEnd {
            logger.warning(
                "Conversation page cap (\(self.maxConversationPages, privacy: .public)) hit for \(folder.rawValue, privacy: .public); skipping tombstoning to avoid deleting unseen pages"
            )
            return changes
        }
        try checkPassIsCurrent()
        changes.formUnion(
            try await store.deleteMissingConversations(
                accountID: accountID,
                mailboxID: mailboxID,
                folder: folder,
                keeping: seen
            )
        )
        return changes
    }

    /// The server's `GET /messages` has no pagination param in v1 but SILENTLY caps
    /// the response at this many rows (worker/features/messages/queries.ts:
    /// `LIMIT ?` with limit clamped to 100). A response of exactly this size may be
    /// truncated, so it must not be treated as "the whole folder".
    static let serverMessageListCap = 100

    /// Page size asked for on `GET /messages` and `GET /changes` (the servers'
    /// maximum, and their default).
    static let messagePageLimit = 100
    static let changePageLimit = 100

    /// Lists one folder and tombstones what the server stopped returning.
    ///
    /// Two servers, one function:
    /// - **Paginating** (a `Link` header appeared, now or earlier this session):
    ///   page-walk to the end and tombstone normally — the listing is complete.
    /// - **Pre-pagination**: one call is the whole folder ONLY when it comes back
    ///   below the silent 100-row cap; a full-cap response may be truncated and
    ///   tombstoning is skipped, or every message the server didn't get to return
    ///   would be erased from the cache on every pass.
    private func syncMessages(
        accountID: String,
        mailboxID: String,
        folder: MailFolder
    ) async throws -> ChangeSet {
        var changes = ChangeSet()
        var seen: Set<String> = []
        var cursor: String?
        var pages = 0
        var reachedEnd = false
        var paginates = paginatingAccounts.contains(accountID)

        while pages < maxMessagePages {
            try checkPassIsCurrent()
            let page = try await api.listMessages(
                folder: folder,
                mailboxID: mailboxID,
                search: nil,
                limit: Self.messagePageLimit,
                cursor: cursor
            )
            pages += 1
            if page.nextCursor != nil {
                paginatingAccounts.insert(accountID)
                paginates = true
            }
            seen.formUnion(page.messages.map(\.id))
            changes.formUnion(try await store.upsertMessages(page.messages, accountID: accountID))
            guard let next = page.nextCursor else {
                // No next link: the end of a paginated walk, or a whole listing
                // from a server that cannot paginate at all.
                reachedEnd = paginates || page.messages.count < Self.serverMessageListCap
                if !reachedEnd {
                    logger.warning(
                        "Message list hit the pre-pagination server cap (\(page.messages.count, privacy: .public)); skipping tombstoning to avoid deleting unreturned mail"
                    )
                }
                break
            }
            cursor = next
        }

        guard reachedEnd else {
            if pages >= maxMessagePages {
                logger.warning(
                    "Message page cap (\(self.maxMessagePages, privacy: .public)) hit for \(folder.rawValue, privacy: .public); skipping tombstoning to avoid deleting unseen pages"
                )
            }
            return changes
        }
        try checkPassIsCurrent()
        changes.formUnion(
            try await store.deleteMissingMessages(
                accountID: accountID,
                mailboxID: mailboxID,
                folder: folder,
                keeping: seen
            )
        )
        return changes
    }

    private func emit(_ event: SyncEvent) {
        eventContinuation.yield(event)
    }
}
