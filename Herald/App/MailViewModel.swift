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
    private let api: any MailAPIClient
    private let store: MailStore
    private let actions: MailActionService
    private let sync: (any MailSyncing)?
    private let events: AsyncStream<SyncEvent>
    /// How long a message must stay selected before it is marked read. Injected
    /// so tests can drive both sides of the rule without real waiting.
    private let markReadDelay: Duration

    // MARK: Published state

    private(set) var mailboxes: [Mailbox] = []
    /// Unread conversation counts per (mailbox, folder) scope.
    private(set) var unreadCounts: [FolderSelection: Int] = [:]

    var selection: FolderSelection {
        didSet {
            guard selection != oldValue else { return }
            selectedThreadID = nil
            reloadTask = Task { await reloadConversations() }
        }
    }

    /// Everything the store holds for the current scope, before search.
    private(set) var allConversations: [ConversationSummary] = []

    /// Committed search text (the field debounces before pushing here). It only
    /// narrows the presented list — never the loaded slice, so the reading pane
    /// does not re-render on a keystroke.
    var searchQuery: String = ""

    var selectedThreadID: String? {
        didSet {
            guard selectedThreadID != oldValue else { return }
            threadTask?.cancel()
            let threadID = selectedThreadID
            threadMessages = []
            selectedMessageID = nil
            guard let threadID else { return }
            threadTask = Task { await loadThread(threadID) }
        }
    }

    private(set) var threadMessages: [MessageSummary] = []

    var selectedMessageID: String? {
        didSet {
            guard selectedMessageID != oldValue else { return }
            detailTask?.cancel()
            markReadTask?.cancel()
            detail = nil
            body = nil
            guard let messageID = selectedMessageID else { return }
            detailTask = Task { await loadDetail(messageID) }
            markReadTask = Task { await markReadAfterDwell(messageID) }
        }
    }

    private(set) var detail: MessageDetail?
    private(set) var body: RenderedBody?
    private(set) var isLoadingBody = false
    private(set) var status: SyncStatus = .idle
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

    private var reloadTask: Task<Void, Never>?
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
        markReadDelay: Duration = .seconds(1)
    ) {
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

    /// Rows the list shows: the scope's conversations minus anything a local
    /// action moved out of it, filtered by the committed search text.
    ///
    /// Selection is always resolved against ``allConversations``, never this, so
    /// typing in the search field cannot tear down the reading pane.
    var conversations: [ConversationSummary] {
        let inScope = allConversations.filter { Self.belongs($0, to: selection.folder) }
        guard !searchQuery.isEmpty else { return inScope }
        let needle = searchQuery.lowercased()
        return inScope.filter { row in
            row.latest.subject.lowercased().contains(needle)
                || row.latest.fromAddress.lowercased().contains(needle)
                || row.latest.snippet.lowercased().contains(needle)
        }
    }

    var selectedConversation: ConversationSummary? {
        guard let selectedThreadID else { return nil }
        return allConversations.first { $0.id == selectedThreadID }
    }

    var selectedMessage: MessageSummary? {
        guard let selectedMessageID else { return nil }
        return threadMessages.first { $0.id == selectedMessageID }
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

    func refresh() async {
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
                if status != .needsReauth { status = .idle }
            case .changed(let changes):
                await apply(changes)
            case .failed(let error):
                if let apiError = error as? MailAPIError, apiError == .unauthorized {
                    status = .needsReauth
                } else {
                    status = .failed(error.localizedDescription)
                }
            }
        }
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
                guard let message = try? await store.message(id: id) else {
                    // Not a message id — a mailbox or a thread-only row.
                    if visibleThreads.contains(id) { reloadConversationList = true }
                    if id == selectedThreadID { reloadThread = true }
                    if mailboxes.contains(where: { $0.id == id }) { reloadMailboxList = true }
                    continue
                }
                if message.threadID == selectedThreadID { reloadThread = true }
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
            mailboxes = try await store.mailboxes(accountID: accountID)
        } catch {
            logger.error("Mailbox load failed: \(error.localizedDescription, privacy: .public)")
        }
        await reloadUnreadCounts()
    }

    func reloadConversations() async {
        conversationReloadCount += 1
        do {
            allConversations = try await store.conversations(
                accountID: accountID,
                mailboxID: selection.mailboxID,
                folder: selection.folder
            )
        } catch {
            logger.error("Conversation load failed: \(error.localizedDescription, privacy: .public)")
            allConversations = []
        }
        if let selectedThreadID, !allConversations.contains(where: { $0.id == selectedThreadID }) {
            self.selectedThreadID = nil
        }
        await reloadUnreadCounts()
    }

    /// Inbox unread badges only — the other folders do not carry a count in the
    /// sidebar, so fetching them would be work nobody reads.
    private func reloadUnreadCounts() async {
        var counts: [FolderSelection: Int] = [:]
        for mailbox in mailboxes {
            let scope = FolderSelection(mailboxID: mailbox.id, folder: .inbox)
            do {
                let rows = try await store.conversations(
                    accountID: accountID,
                    mailboxID: mailbox.id,
                    folder: .inbox
                )
                let unread = rows.count { $0.isUnread && Self.belongs($0, to: .inbox) }
                if unread > 0 { counts[scope] = unread }
            } catch {
                logger.error("Unread count failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        counts[FolderSelection(mailboxID: nil, folder: .inbox)] = counts.values.reduce(0, +)
        unreadCounts = counts.filter { $0.value > 0 }
    }

    func loadThread(_ threadID: String) async {
        threadReloadCount += 1
        do {
            let messages = try await store.messages(accountID: accountID, threadID: threadID)
            guard !Task.isCancelled, selectedThreadID == threadID else { return }
            threadMessages = messages
            if selectedMessageID == nil || !messages.contains(where: { $0.id == selectedMessageID }) {
                selectedMessageID = messages.last?.id
            }
        } catch {
            logger.error("Thread load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Message detail and body

    private func loadDetail(_ messageID: String) async {
        isLoadingBody = true
        defer { isLoadingBody = false }
        do {
            // Attachments and the full recipient list are not cached, so the
            // single-message route is the source here (never a list route).
            let loaded = try await api.message(id: messageID)
            guard !Task.isCancelled, selectedMessageID == messageID else { return }
            detail = loaded
            await loadBody(for: loaded, allowRemote: false)
        } catch {
            logger.warning("Message detail failed: \(error.localizedDescription, privacy: .public)")
            guard selectedMessageID == messageID else { return }
            actionError = error.localizedDescription
        }
    }

    private func loadBody(for detail: MessageDetail, allowRemote: Bool) async {
        let messageID = detail.id
        guard detail.htmlAvailable else {
            let text = detail.textBody
            let rendered = await Task.detached(priority: .userInitiated) { @Sendable in
                Self.document(wrappingPlainText: text)
            }.value
            guard selectedMessageID == messageID else { return }
            body = RenderedBody(messageID: messageID, html: rendered, blocksRemote: true, offersRemoteConsent: false)
            await cacheBody(messageID: messageID, text: text, html: nil)
            return
        }

        do {
            let payload = try await api.messageHTML(id: messageID, loadRemoteImages: allowRemote)
            guard !Task.isCancelled, selectedMessageID == messageID else { return }
            let inline = try await inlineImages(for: detail)
            guard !Task.isCancelled, selectedMessageID == messageID else { return }
            let raw = payload.html
            // Substitution walks the whole body; never on the main actor.
            let substituted = await Task.detached(priority: .userInitiated) { @Sendable in
                Self.document(wrapping: Self.substituteInlineImages(in: raw, with: inline))
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
            logger.warning("Message HTML failed: \(error.localizedDescription, privacy: .public)")
            guard selectedMessageID == messageID else { return }
            // Fall back to the cached copy so an offline read still shows something.
            if let cached = try? await store.cachedBody(messageID: messageID), let html = cached.html {
                let wrapped = await Task.detached(priority: .userInitiated) { @Sendable in
                    Self.document(wrapping: html)
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
            logger.error("Body cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fetches inline parts as data so `cid:` references can be rewritten. The
    /// web view is never allowed to fetch them itself.
    private func inlineImages(for detail: MessageDetail) async throws -> [String: String] {
        let inlineParts = detail.attachments.filter(\.isInline)
        guard !inlineParts.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for part in inlineParts {
            guard let contentID = part.contentID else { continue }
            do {
                let payload = try await api.inlineImage(messageID: detail.id, attachmentID: part.id)
                let encoded = await Task.detached(priority: .userInitiated) { @Sendable [payload] in
                    "data:\(payload.mimeType);base64,\(payload.data.base64EncodedString())"
                }.value
                result[Self.normalizedContentID(contentID)] = encoded
            } catch {
                logger.warning("Inline image \(part.id, privacy: .public) unavailable")
            }
        }
        return result
    }

    /// User consented to remote media for this sender: tell the server (so the
    /// web app agrees) and re-render without the blocking rule list.
    func trustRemoteMedia() async {
        guard let detail else { return }
        do {
            try await api.trustRemoteMedia(messageID: detail.id)
        } catch {
            logger.warning("Remote-media trust failed: \(error.localizedDescription, privacy: .public)")
            actionError = error.localizedDescription
            return
        }
        await loadBody(for: detail, allowRemote: true)
    }

    // MARK: - Actions

    func perform(_ action: MessageAction, on messageID: String) async {
        do {
            try await actions.perform(action, on: messageID, accountID: accountID)
        } catch {
            actionError = error.localizedDescription
        }
        await reloadAfterAction(threadID: threadMessages.first(where: { $0.id == messageID })?.threadID)
    }

    func perform(_ action: ConversationAction, onThread threadID: String) async {
        do {
            try await actions.perform(
                action,
                onConversation: threadID,
                in: selection.folder,
                accountID: accountID
            )
        } catch {
            actionError = error.localizedDescription
        }
        await reloadAfterAction(threadID: threadID)
    }

    /// The optimistic write already landed in the cache (and was reverted there if
    /// the server said no), so the slice reload is what makes either outcome visible.
    private func reloadAfterAction(threadID: String?) async {
        await reloadConversations()
        if let threadID, threadID == selectedThreadID { await loadThread(threadID) }
        await refresh()
    }

    /// Convenience for the commands: act on the current selection.
    func performOnSelection(_ action: ConversationAction) async {
        guard let threadID = selectedThreadID else { return }
        await perform(action, onThread: threadID)
    }

    func toggleStar(_ row: ConversationSummary) async {
        await perform(row.isStarred ? .unstar : .star, onThread: row.id)
    }

    func toggleRead(_ row: ConversationSummary) async {
        await perform(row.isUnread ? .read : .unread, onThread: row.id)
    }

    /// Runs the save panel and writes the attachment. The API client stays private
    /// to the view-model; views ask for the action, not the bytes.
    func saveAttachment(_ attachment: Attachment) async {
        if let message = await AttachmentSaver.save(attachment, using: api) {
            actionError = message
        }
    }

    func requestCompose(_ kind: ComposeRequest.Kind) {
        composeRequest = ComposeRequest(
            kind: kind,
            messageID: selectedMessageID,
            mailboxID: selection.mailboxID ?? selectedMessage?.mailboxID
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
        guard let message = try? await store.message(id: messageID), message.isUnread else { return }
        do {
            try await actions.perform(.read, on: messageID, accountID: accountID)
        } catch {
            logger.warning("Auto mark-read failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        await reloadConversations()
        if let threadID = selectedThreadID { await loadThread(threadID) }
    }

    // MARK: - HTML assembly

    nonisolated static func normalizedContentID(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }

    /// Replaces `cid:` references with the data URLs we already fetched.
    nonisolated static func substituteInlineImages(in html: String, with images: [String: String]) -> String {
        guard !images.isEmpty else { return html }
        var output = html
        for (contentID, dataURL) in images {
            output = output.replacingOccurrences(of: "cid:\(contentID)", with: dataURL)
            output = output.replacingOccurrences(of: "cid:<\(contentID)>", with: dataURL)
        }
        return output
    }

    nonisolated static func document(wrapping bodyHTML: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(styleSheet)</style></head><body>\(bodyHTML)</body></html>
        """
    }

    nonisolated static func document(wrappingPlainText text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return document(wrapping: "<pre class=\"plain\">\(escaped)</pre>")
    }

    private nonisolated static let styleSheet = """
        :root { color-scheme: light dark; }
        body { font: -apple-system-body; font-family: -apple-system, system-ui, sans-serif;
               margin: 16px; word-break: break-word; }
        img, video, table { max-width: 100%; height: auto; }
        pre.plain { font-family: ui-monospace, SFMono-Regular, monospace; white-space: pre-wrap; }
        blockquote { border-left: 3px solid rgba(127,127,127,.4); margin-left: 0; padding-left: 12px; }
        """
}
