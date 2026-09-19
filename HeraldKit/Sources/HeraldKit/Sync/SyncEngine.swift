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
    /// The LABELS table (or its assignments) changed — either the reconciliation
    /// wrote something, or a pass upserted message rows whose EMBEDDED labels
    /// moved. Its own case for the same
    /// reason as `draftsChanged`: label ids and assignment rows are not message
    /// ids, so folding them into a ``ChangeSet`` would have the view-model
    /// resolving them against the message cache and reloading the wrong slices.
    case labelsChanged
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

/// Polling cadence: 15s while a window is key, 60s when idle.
///
/// Polling is the FLOOR, not the mechanism. Upstream 1.3.4 added a wake socket
/// (`GET /events`), and while it is connected the interval stretches — but it
/// never goes away, because the server documents those frames as wake-only and
/// explicitly not reliable delivery, and because a socket that dies silently
/// must not take mail delivery with it.
public nonisolated enum SyncCadence: Sendable, Hashable {
    case active
    case idle

    var interval: Duration {
        switch self {
        case .active: .seconds(15)
        case .idle: .seconds(60)
        }
    }

    /// The interval used while the wake socket is connected.
    ///
    /// Not "never": these are the safety net for a frame the server dropped, a
    /// socket that is half-open without knowing it, and the two surfaces whose
    /// staleness a frame cannot fix (the drafts poll and the label reconciliation
    /// only ever run inside a pass, and a label DELETED workspace-wide is
    /// announced by nothing the message journal carries). Active stays at two
    /// minutes for exactly that reason.
    var stretchedInterval: Duration {
        switch self {
        case .active: .seconds(120)
        case .idle: .seconds(300)
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

    /// How rarely a rejected change cursor may be answered with a full
    /// re-bootstrap. See ``journalSync(accountID:)`` — the recovery looks like a
    /// SUCCESSFUL pass, so without a limit a persistently rejected cursor is an
    /// invisible re-listing loop.
    public static let defaultRebootstrapCooldown: Duration = .seconds(300)

    // ACCESS LEVELS: the members below are internal rather than `private`
    // because `SyncEngine+Labels.swift` and `SyncEngine+Drafts.swift` are
    // extensions of this actor in OTHER FILES, and `private` in Swift is
    // file-scoped. `fileprivate` would be no better for the same reason. They
    // are still invisible outside HeraldKit (the app sees only the `public`
    // surface), and the actor still serializes every access, so the isolation
    // the `private` was never providing is unchanged.
    let api: any MailAPIClient
    let store: MailStore
    private let scope: SyncScope
    private let maxConversationPages: Int
    let maxMessagePages: Int
    let draftPollInterval: Duration
    let labelPollInterval: Duration
    let idleLabelPollInterval: Duration
    let reconciliationLabelPollInterval: Duration
    private let rebootstrapCooldown: Duration

    /// When the drafts list was last read. `nil` means "never", which is what
    /// makes the first pass of a session always poll them.
    var lastDraftPoll: ContinuousClock.Instant?
    /// Same, for the label sweep.
    var lastLabelPoll: ContinuousClock.Instant?

    /// Whether anything on screen currently shows labels. Drives which of the two
    /// LEGACY label intervals applies — see ``setLabelSurfaceVisible(_:)``.
    var isLabelSurfaceVisible = false

    /// Accounts whose server has been SEEN to embed label membership on message
    /// rows, which is what demotes the sweep to a reconciliation. The detection
    /// rule — and why `nil` is never evidence of anything — is documented on
    /// ``noteLabelEmbedding(in:accountID:)`` in `SyncEngine+Labels.swift`, which
    /// is the only thing that writes it. Storage cannot live in an extension, so
    /// the property stays here and its reasoning went with its code.
    var labelEmbeddingAccounts: Set<String> = []

    /// What the last COMPLETED sweep wrote for each label, as a digest. Same
    /// split as above: ``SyncEngine/SweepDigest`` and the argument for why
    /// skipping a matching sweep is safe live in `SyncEngine+Labels.swift`.
    var lastSweepDigests: [String: SweepDigest] = [:]

    private let eventStream: AsyncStream<SyncEvent>
    private let eventContinuation: AsyncStream<SyncEvent>.Continuation

    var accountID: String?
    private var loopTask: Task<Void, Never>?
    private var cadence: SyncCadence = .active
    /// Whether the wake socket is delivering. Stretches the poll while true.
    private var isWakeSocketConnected = false
    private var consecutiveFailures = 0

    /// Whether THIS pass wrote any embedded label membership. Raised by the
    /// upsert paths, drained into one `.labelsChanged` at the end of the pass.
    private var passLabelsChanged = false

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
        draftPollInterval: Duration = SyncEngine.defaultDraftPollInterval,
        labelPollInterval: Duration = SyncEngine.defaultLabelPollInterval,
        idleLabelPollInterval: Duration = SyncEngine.defaultIdleLabelPollInterval,
        reconciliationLabelPollInterval: Duration = SyncEngine.defaultReconciliationLabelPollInterval,
        rebootstrapCooldown: Duration = SyncEngine.defaultRebootstrapCooldown
    ) {
        self.api = api
        self.store = store
        self.scope = scope
        self.maxConversationPages = max(1, maxConversationPages)
        self.maxMessagePages = max(1, maxMessagePages)
        self.draftPollInterval = draftPollInterval
        self.labelPollInterval = labelPollInterval
        // A caller that shortens the visible interval past the idle one means the
        // shorter number; the idle interval is a FLOOR on rarity, never a way to
        // sweep more often than the visible surface asked for.
        self.idleLabelPollInterval = max(idleLabelPollInterval, labelPollInterval)
        self.reconciliationLabelPollInterval = reconciliationLabelPollInterval
        self.rebootstrapCooldown = rebootstrapCooldown
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
        lastLabelPoll = nil
        // The digests describe the PREVIOUS account's membership; keeping them
        // would let the first sweep of a new account skip a write it must make.
        lastSweepDigests.removeAll()
        // Re-decided from this account's own first row (see
        // ``labelEmbeddingAccounts``): a server can be upgraded — or rolled back —
        // between one engine and the next, and the answer costs one field test.
        labelEmbeddingAccounts.removeAll()
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

    /// Switches the poll interval. Takes effect on the next wait, and wakes the
    /// loop when speeding up so the change is not delayed by a full idle period.
    public func setCadence(_ cadence: SyncCadence) {
        guard cadence != self.cadence else { return }
        self.cadence = cadence
        if cadence == .active { signalWake() }
    }

    /// Tells the loop whether the wake socket is currently delivering.
    ///
    /// Healthy → the poll stretches to ``SyncCadence/stretchedInterval``, because
    /// the socket is what makes a change visible now and the poll is only the
    /// backstop. Unhealthy → back to the full cadence IMMEDIATELY: the loop is
    /// woken so a socket that dropped during a two-minute wait does not leave the
    /// user waiting out the rest of it with nothing watching the server.
    ///
    /// Deliberately NOT a "stop polling" switch. The frames are wake-only and
    /// undelivered ones are never replayed, so a poll that never runs is a cache
    /// that silently diverges the first time a frame is missed.
    public func setWakeSocketConnected(_ connected: Bool) {
        guard connected != isWakeSocketConnected else { return }
        isWakeSocketConnected = connected
        if !connected { signalWake() }
    }

    /// Test seam: the interval the NEXT wait will use.
    var currentPollInterval: Duration {
        backoffInterval ?? (isWakeSocketConnected ? cadence.stretchedInterval : cadence.interval)
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
        let interval = currentPollInterval
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
    func checkPassIsCurrent() throws {
        try Task.checkCancellation()
        guard runningPassGeneration == passGeneration else { throw CancellationError() }
    }

    private func runPass(accountID: String) async {
        isSyncing = true
        runningPassGeneration = passGeneration
        passLabelsChanged = false
        defer { isSyncing = false }
        // DRAINED ON EVERY EXIT, not just the success path. A pass whose first
        // journal page wrote embedded labels and whose second page threw has
        // already moved membership the UI is now drawing wrong, and on an
        // embedding server the next reconciliation is up to half an hour away —
        // so the chips would stay stale for that long because of an unrelated
        // failure. Safe to do unconditionally: the event carries no payload and
        // the view-model's answer to it is one idempotent index reload, so an
        // extra one costs a fetch and a redraw of what is already on screen.
        // The success path drains it EARLIER, purely so `.labelsChanged`
        // precedes `.finished`; this defer is then a no-op.
        defer { drainLabelsChanged() }
        emit(.began)
        do {
            let changes = try await syncEverything(accountID: accountID)
            try checkPassIsCurrent()
            consecutiveFailures = 0
            if !changes.isEmpty { emit(.changed(changes)) }
            drainLabelsChanged()
            // Deliberately AFTER the mail sync and outside its result: drafts are
            // a separate surface on a separate cadence, and their own failure
            // mode must not decide whether the mail pass succeeded.
            await syncDraftsIfDue(accountID: accountID)
            // Same contract as the drafts poll: its own cadence, its own failure
            // mode, and never able to fail the mail pass.
            await syncLabelsIfDue(accountID: accountID)
            emit(.finished)
        } catch let error as MailAPIError where error == .unauthorized {
            // Nothing the loop can do: the UI has to re-authenticate. Stop
            // rather than hammer the server with doomed requests.
            logger.warning("Sync stopped: token rejected, re-authentication required")
            // Before the failure, so the UI corrects its chips and THEN shows the
            // banner. The `defer` above is the backstop that makes the drain
            // unconditional; these two calls only decide the order.
            drainLabelsChanged()
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
            drainLabelsChanged()
            emit(.failed(error))
        }
    }

    /// Emits the pass's one coalesced `.labelsChanged`, if it raised the flag.
    ///
    /// Coalesced to ONE event for the whole pass: a journal page can carry a
    /// hundred label edits and the view-model's answer to each is the same
    /// whole-account index reload. Idempotent, and clears the flag, so calling
    /// it twice on one pass emits once.
    private func drainLabelsChanged() {
        guard passLabelsChanged else { return }
        passLabelsChanged = false
        emit(.labelsChanged)
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
    var draftlessAccounts: Set<String> = []

    nonisolated static func isScopeRefusal(_ error: MailAPIError) -> Bool {
        if case .insufficientScope = error { return true }
        if case .server(let code, _) = error { return code == "http_403" }
        return false
    }

    // MARK: - Labels

    /// Accounts whose token cannot read labels at all — or whose server predates
    /// them (a 404 on `GET /labels`). Same reasoning as ``draftlessAccounts``: a
    /// permanent refusal must not park a healthy mailbox in backoff. Probed again
    /// when the engine restarts, which is what makes a server upgrade take effect.
    var labellessAccounts: Set<String> = []

    /// Accounts whose server has already answered `GET /labels` successfully.
    ///
    /// A 404 means "no such route" ONLY before that: once an account has read its
    /// labels, a later 404 is a transient server fault (a bad deploy, a proxy) and
    /// treating it as "this server has no labels" would silently drop the feature
    /// for the rest of the session. Exactly the rule ``fetchChanges`` follows for
    /// the change journal.
    var labelCapableAccounts: Set<String> = []

    /// Test seam: how many times a sweep has reached `replaceAssignments`, which
    /// is what makes "the second sweep of an unchanged membership skipped the
    /// store write" assertable — the store's own return value cannot, because a
    /// no-op write and a skipped write both report `false`.
    var labelAssignmentWrites = 0

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
    var paginatingAccounts: Set<String> = []

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
        // A legacy server has no checkpoint to ask, so "first pass" is read off
        // the cache itself: an account with no cached mailbox has never been
        // listed, and this pass will report its whole inbox as inserted.
        let isBootstrap = try await store.mailboxes(accountID: accountID).isEmpty
        var changes = ChangeSet(isBootstrap: isBootstrap)
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
            // Rate-limited, because a re-bootstrap reports SUCCESS: it re-lists
            // every mailbox and flags the result as a bootstrap, so
            // notifications stay silent, no failure is counted, no backoff
            // starts and no banner appears. A server that keeps rejecting the
            // cursor it just issued would therefore have Herald re-listing
            // everything on every single tick, invisibly and forever. Once per
            // cooldown; anything sooner is an ordinary failure the user can see
            // and the backoff can slow down.
            if let last = lastRebootstrapAt[accountID], last.duration(to: .now) < rebootstrapCooldown {
                logger.error("Change cursor rejected again right after a re-bootstrap; reporting it as a failure")
                throw error
            }
            lastRebootstrapAt[accountID] = .now
            logger.warning("Change cursor rejected; discarding the checkpoint and re-bootstrapping")
            try await store.clearSyncCheckpoint(accountID: accountID)
            return try await bootstrap(accountID: accountID)
        }
    }

    /// When this account last recovered from a rejected cursor.
    private var lastRebootstrapAt: [String: ContinuousClock.Instant] = [:]

    /// Checkpoint FIRST, then the full listing, then the changes that landed
    /// while the listing ran. Taking the checkpoint afterwards would silently
    /// drop every change made during the listing.
    private func bootstrap(accountID: String) async throws -> ChangeSet {
        let checkpoint = try await fetchChanges(cursor: nil)
        // Every row this pass writes is "new" only to the cache — the flag keeps
        // new-mail notifications silent for it (see ``ChangeSet/isBootstrap``).
        var changes = ChangeSet(isBootstrap: true)
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
            var listed = try await syncMailbox(accountID: accountID, mailboxID: mailbox.id)
            // A mailbox the cache has never seen is being bootstrapped even in a
            // steady-state pass: its entire inbox arrives as inserted rows, and
            // notifying for all of it is exactly the burst this flag prevents.
            if isNew { listed.isBootstrap = true }
            changes.formUnion(listed)
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
        noteLabelEmbedding(in: upserts, accountID: accountID)
        let result = try await store.applyMessageUpserts(upserts, accountID: accountID)
        // A label-only edit is a journal upsert whose message fields are all
        // identical, so `result.changes` is empty and `.changed` is never emitted
        // — this flag is the only thing that will tell the UI its chips moved.
        if result.labelsChanged { passLabelsChanged = true }
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
            noteLabelEmbedding(in: page.messages, accountID: accountID)
            let upserted = try await store.applyMessageUpserts(page.messages, accountID: accountID)
            changes.formUnion(upserted.changes)
            if upserted.labelsChanged { passLabelsChanged = true }
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

    func emit(_ event: SyncEvent) {
        eventContinuation.yield(event)
    }
}
