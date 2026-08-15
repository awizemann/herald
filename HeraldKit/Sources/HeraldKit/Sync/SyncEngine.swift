import Foundation
import OSLog

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "SyncEngine")

/// What the sync loop tells the UI. `.changed` is only emitted when something
/// actually changed, so an unchanged poll never invalidates a view.
public nonisolated enum SyncEvent: Sendable {
    case began
    case changed(ChangeSet)
    case finished
    case failed(any Error)
}

/// One folder the engine keeps in sync, plus the conversation-listing folder it
/// maps to. `drafts` has no conversation counterpart (the conversation surface
/// swaps `drafts` for `starred`), so its conversation walk is skipped.
public nonisolated struct SyncFolder: Sendable, Hashable {
    public let message: MailFolder
    public let conversation: ConversationFolder?

    public init(message: MailFolder, conversation: ConversationFolder?) {
        self.message = message
        self.conversation = conversation
    }

    public static let inbox = SyncFolder(message: .inbox, conversation: .inbox)
    public static let sent = SyncFolder(message: .sent, conversation: .sent)
    public static let archived = SyncFolder(message: .archived, conversation: .archived)
    public static let trash = SyncFolder(message: .trash, conversation: .trash)
    public static let drafts = SyncFolder(message: .drafts, conversation: nil)
    public static let catchall = SyncFolder(message: .catchall, conversation: .catchall)
}

/// Which folders one pass covers.
public nonisolated struct SyncScope: Sendable, Hashable {
    public var folders: [SyncFolder]

    public init(folders: [SyncFolder]) { self.folders = folders }

    /// The four folders the UI shows by default.
    public static let `default` = SyncScope(folders: [.inbox, .sent, .archived, .trash])
    /// Adds the optional surfaces.
    public static let complete = SyncScope(folders: [.inbox, .sent, .archived, .trash, .drafts, .catchall])
}

/// Polling cadence. The server has no delta endpoint and no push, so the client
/// polls: 15s while a window is key, 60s when idle.
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

    private let api: any MailAPIClient
    private let store: MailStore
    private let scope: SyncScope
    private let maxConversationPages: Int

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

    /// Wait state: the loop parks on `wakeContinuation` until either the cadence
    /// timer or `refreshNow()`/`stop()` resumes it.
    private var wakeContinuation: CheckedContinuation<Void, Never>?
    private var wakeSignalled = false

    public init(
        api: any MailAPIClient,
        store: MailStore,
        scope: SyncScope = .default,
        maxConversationPages: Int = SyncEngine.defaultMaxConversationPages
    ) {
        self.api = api
        self.store = store
        self.scope = scope
        self.maxConversationPages = max(1, maxConversationPages)
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
        loopTask = Task { [weak self] in
            await self?.runLoop(accountID: accountID)
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        refreshPending = false
        signalWake()
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
            await self?.signalWake()
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

    private func runPass(accountID: String) async {
        isSyncing = true
        defer { isSyncing = false }
        emit(.began)
        do {
            let changes = try await syncEverything(accountID: accountID)
            consecutiveFailures = 0
            if !changes.isEmpty { emit(.changed(changes)) }
            emit(.finished)
        } catch let error as MailAPIError where error == .unauthorized {
            // Nothing the loop can do: the UI has to re-authenticate. Stop
            // rather than hammer the server with doomed requests.
            logger.warning("Sync stopped: token rejected, re-authentication required")
            emit(.failed(error))
            stop()
        } catch is CancellationError {
            logger.warning("Sync pass cancelled")
        } catch {
            consecutiveFailures += 1
            logger.warning(
                "Sync pass \(self.consecutiveFailures, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            emit(.failed(error))
        }
    }

    private func syncEverything(accountID: String) async throws -> ChangeSet {
        var changes = ChangeSet()
        let mailboxes = try await api.listMailboxes()
        changes.formUnion(try await store.upsertMailboxes(mailboxes, accountID: accountID))

        for mailbox in mailboxes {
            for folder in scope.folders {
                try Task.checkCancellation()
                if let conversationFolder = folder.conversation {
                    changes.formUnion(
                        try await syncConversations(
                            accountID: accountID,
                            mailboxID: mailbox.id,
                            folder: conversationFolder
                        )
                    )
                }
                changes.formUnion(
                    try await syncMessages(accountID: accountID, mailboxID: mailbox.id, folder: folder.message)
                )
            }
        }
        return changes
    }

    /// Page-walks a folder's conversations until `nextCursor` is nil or the cap
    /// is hit, then tombstones whatever the server stopped returning.
    private func syncConversations(
        accountID: String,
        mailboxID: String,
        folder: ConversationFolder
    ) async throws -> ChangeSet {
        var changes = ChangeSet()
        var seen: Set<String> = []
        var cursor: String?
        var pages = 0
        var reachedEnd = false

        while pages < maxConversationPages {
            try Task.checkCancellation()
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

    /// `GET /messages` has no pagination in v1, so one call is the whole folder
    /// and anything absent from it is gone.
    private func syncMessages(
        accountID: String,
        mailboxID: String,
        folder: MailFolder
    ) async throws -> ChangeSet {
        let messages = try await api.listMessages(folder: folder, mailboxID: mailboxID, search: nil)
        var changes = try await store.upsertMessages(messages, accountID: accountID)
        changes.formUnion(
            try await store.deleteMissingMessages(
                accountID: accountID,
                mailboxID: mailboxID,
                folder: folder,
                keeping: Set(messages.map(\.id))
            )
        )
        return changes
    }

    private func emit(_ event: SyncEvent) {
        eventContinuation.yield(event)
    }
}
