import Foundation
@testable import HeraldKit

/// Scripted `MailAPIClient` with call recording and a gate.
///
/// The gate exists so engine tests can hold a pass open deterministically
/// instead of sleeping: arm it, let the pass reach the first request, poke the
/// engine, then open it. No test in this suite measures time.
actor FakeMailAPIClient: MailAPIClient {
    /// Every call the engine made, in order.
    enum Call: Sendable, Hashable {
        case listMailboxes
        case listConversations(folder: ConversationFolder?, mailboxID: String?, cursor: String?)
        case listMessages(folder: MailFolder?, mailboxID: String?, cursor: String?)
        case changes(cursor: String?)
        case performMessage(MessageAction, String)
        case performConversation(ConversationAction, String, ConversationFolder)
        // Compose surface (P0.5). Additive: the sync suite matches its own cases.
        case listDrafts
        case createDraft(DraftInput)
        case fetchDraft(String)
        case updateDraft(id: String, version: Int?)
        case deleteDraft(String)
        case addAttachment(draftID: String, filename: String, bytes: Int)
        case removeAttachment(draftID: String, attachmentID: String)
        case sendMessage(SendInput)
        case replyToMessage(ReplyInput)
    }

    private(set) var calls: [Call] = []

    // MARK: Script
    private var mailboxes: [Mailbox] = []
    /// Conversation pages keyed by the cursor that requests them ("" = first page).
    private var conversationPages: [String: ConversationPage] = [:]
    private var messagesByFolder: [MailFolder: [MessageSummary]] = [:]
    /// Scripted message pages keyed by (scope, cursor). Present only for the
    /// scopes a test paginates; every other scope answers from `messagesByFolder`
    /// with NO Link header — which is exactly how a pre-pagination server behaves.
    private var messagePages: [MessagePageKey: MessagePage] = [:]
    private var listFailure: MailAPIError?
    private var actionFailure: MailAPIError?
    /// `GET /messages` failures scoped to ONE mailbox, so a test can break a
    /// single mailbox's listing without also breaking `GET /mailboxes`.
    private var messageListFailures: [String: MailAPIError] = [:]
    /// The `limit` the engine asked for, per `listMessages` call, in order.
    private var recordedMessageLimits: [Int?] = []

    // MARK: Changes feed
    /// `false` = a server that predates `GET /changes` (404 on the route).
    private var supportsChanges = false
    private var checkpointCursor = "chk_0"
    private var changePagesByCursor: [String: ChangePage] = [:]
    private var changeFailures: [String: MailAPIError] = [:]

    struct MessagePageKey: Hashable, Sendable {
        var folder: MailFolder?
        var mailboxID: String?
        var cursor: String?
    }

    // MARK: Gate
    private var gateArmed = false
    private var gateOpened = false
    private var gateContinuation: CheckedContinuation<Void, Never>?

    init() {}

    // MARK: Scripting

    func setMailboxes(_ mailboxes: [Mailbox]) { self.mailboxes = mailboxes }

    /// `pages[i].nextCursor` chains to `pages[i + 1]`.
    func setConversationPages(_ pages: [ConversationPage]) {
        conversationPages = [:]
        var cursor = ""
        for page in pages {
            conversationPages[cursor] = page
            cursor = page.nextCursor ?? "\u{0}end"
        }
    }

    func setMessages(_ messages: [MessageSummary], folder: MailFolder) {
        messagesByFolder[folder] = messages
    }

    /// Scripts a paginated listing for one scope: page `i` links to page `i + 1`
    /// through the `Link`-derived cursor, and the last page has none.
    func setMessagePages(_ pages: [[MessageSummary]], folder: MailFolder?, mailboxID: String?) {
        var cursor: String?
        for (index, page) in pages.enumerated() {
            let next: String? = index == pages.count - 1
                ? nil
                : "\(folder?.rawValue ?? "all")-\(mailboxID ?? "all")-p\(index + 1)"
            messagePages[MessagePageKey(folder: folder, mailboxID: mailboxID, cursor: cursor)] =
                MessagePage(messages: page, nextCursor: next)
            cursor = next
        }
    }

    func setSupportsChanges(_ supported: Bool) { supportsChanges = supported }
    func setCheckpointCursor(_ cursor: String) { checkpointCursor = cursor }

    /// Chains change pages from the checkpoint cursor: each page is served for
    /// the cursor the previous one handed out.
    func setChangePages(_ pages: [ChangePage]) {
        changePagesByCursor = [:]
        var cursor = checkpointCursor
        for page in pages {
            changePagesByCursor[cursor] = page
            cursor = page.nextCursor
        }
    }

    /// Makes `GET /changes` fail ONCE for exactly one cursor (410, a transport
    /// blip…). One-shot on purpose: a permanent 410 would make the engine's
    /// re-bootstrap fail too, and the test could not tell recovery from a loop.
    func setChangeFailure(_ failure: MailAPIError?, forCursor cursor: String) {
        changeFailures[cursor] = failure
    }

    func changeCursors() -> [String?] {
        calls.compactMap { call in
            guard case .changes(let cursor) = call else { return nil }
            return .some(cursor)
        }
    }

    func messageCursors() -> [String?] {
        calls.compactMap { call in
            guard case .listMessages(_, _, let cursor) = call else { return nil }
            return .some(cursor)
        }
    }

    func conversationScopes() -> [String] {
        calls.compactMap { call in
            guard case .listConversations(let folder, let mailboxID, _) = call else { return nil }
            return "\(mailboxID ?? "all"):\(folder?.rawValue ?? "all")"
        }
    }

    func setListFailure(_ failure: MailAPIError?) { listFailure = failure }

    func setMessageListFailure(_ failure: MailAPIError?, forMailbox mailboxID: String) {
        messageListFailures[mailboxID] = failure
    }

    func messageLimits() -> [Int?] { recordedMessageLimits }
    func setActionFailure(_ failure: MailAPIError?) { actionFailure = failure }

    func callCount(where predicate: @Sendable (Call) -> Bool) -> Int {
        calls.count(where: predicate)
    }

    func conversationCursors() -> [String?] {
        calls.compactMap { call in
            guard case .listConversations(_, _, let cursor) = call else { return nil }
            return .some(cursor)
        }
    }

    // MARK: Gate control

    func armGate() {
        gateArmed = true
        gateOpened = false
    }

    func openGate() {
        gateOpened = true
        if let continuation = gateContinuation {
            gateContinuation = nil
            continuation.resume()
        }
    }

    private func awaitGate() async {
        guard gateArmed, !gateOpened else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gateContinuation = continuation
        }
    }

    // MARK: MailAPIClient

    func listMailboxes() async throws -> [Mailbox] {
        calls.append(.listMailboxes)
        await awaitGate()
        if let listFailure { throw listFailure }
        return mailboxes
    }

    func listMessages(
        folder: MailFolder?,
        mailboxID: String?,
        search: String?,
        limit: Int?,
        cursor: String?
    ) async throws -> MessagePage {
        calls.append(.listMessages(folder: folder, mailboxID: mailboxID, cursor: cursor))
        recordedMessageLimits.append(limit)
        if let listFailure { throw listFailure }
        if let mailboxID, let failure = messageListFailures[mailboxID] { throw failure }
        if let page = messagePages[MessagePageKey(folder: folder, mailboxID: mailboxID, cursor: cursor)] {
            return page
        }
        // The real server CLAMPS to `limit` and never returns more; a fake that
        // ignored it could not tell a client asking for 100 from one asking for 5.
        guard let folder else {
            return MessagePage(messages: Self.clamp(messagesByFolder.values.flatMap { $0 }, to: limit), nextCursor: nil)
        }
        let messages = messagesByFolder[folder] ?? []
        guard let mailboxID else { return MessagePage(messages: Self.clamp(messages, to: limit), nextCursor: nil) }
        return MessagePage(
            messages: Self.clamp(messages.filter { $0.mailboxID == mailboxID }, to: limit),
            nextCursor: nil
        )
    }

    private nonisolated static func clamp(_ messages: [MessageSummary], to limit: Int?) -> [MessageSummary] {
        guard let limit else { return messages }
        return Array(messages.prefix(limit))
    }

    func changes(cursor: String?, limit: Int?) async throws -> ChangePage {
        calls.append(.changes(cursor: cursor))
        // A server without the route answers 404, which is the ONLY signal the
        // engine may read as "no journal here".
        guard supportsChanges else { throw MailAPIError.notFound }
        guard let cursor else {
            return ChangePage(changes: [], nextCursor: checkpointCursor, hasMore: false)
        }
        if let failure = changeFailures.removeValue(forKey: cursor) { throw failure }
        return changePagesByCursor[cursor] ?? ChangePage(changes: [], nextCursor: cursor, hasMore: false)
    }

    func listConversations(
        folder: ConversationFolder?,
        mailboxID: String?,
        search: String?,
        cursor: String?
    ) async throws -> ConversationPage {
        calls.append(.listConversations(folder: folder, mailboxID: mailboxID, cursor: cursor))
        if let listFailure { throw listFailure }
        return conversationPages[cursor ?? ""] ?? ConversationPage(conversations: [], nextCursor: nil, totalCount: nil)
    }

    /// Answers the way the server does: with the updated summary. A fake that
    /// always threw made "a successful action is NOT reverted" untestable — the
    /// revert path was the only one any test could reach.
    @discardableResult
    func perform(_ action: MessageAction, onMessage id: String) async throws -> MessageSummary {
        calls.append(.performMessage(action, id))
        // Gated like the listing calls, so a test can hold a POST open and act on
        // the cache while the optimistic write is still unconfirmed.
        await awaitGate()
        if let actionFailure { throw actionFailure }
        return Self.applying(action, to: SyncFixtures.message(id))
    }

    private nonisolated static func applying(
        _ action: MessageAction,
        to summary: MessageSummary
    ) -> MessageSummary {
        let now = Date(timeIntervalSince1970: 4_000)
        let folder: MailFolder = switch action {
        case .archive: .archived
        case .trash: .trash
        default: summary.folder
        }
        return MessageSummary(
            id: summary.id,
            threadID: summary.threadID,
            mailboxID: summary.mailboxID,
            direction: summary.direction,
            folder: folder,
            fromAddress: summary.fromAddress,
            to: summary.to,
            subject: summary.subject,
            snippet: summary.snippet,
            receivedAt: summary.receivedAt,
            sentAt: summary.sentAt,
            readAt: action == .read ? now : (action == .unread ? nil : summary.readAt),
            starredAt: action == .star ? now : (action == .unstar ? nil : summary.starredAt),
            hasAttachments: summary.hasAttachments,
            createdAt: summary.createdAt
        )
    }

    @discardableResult
    func perform(
        _ action: ConversationAction,
        onConversation id: String,
        in folder: ConversationFolder
    ) async throws -> ConversationActionResult {
        calls.append(.performConversation(action, id, folder))
        if let actionFailure { throw actionFailure }
        return ConversationActionResult(threadID: id, affected: 1)
    }

    // MARK: Unused by the sync suite

    func message(id: String) async throws -> MessageDetail { throw MailAPIError.notFound }
    func thread(messageID: String) async throws -> [MessageDetail] { throw MailAPIError.notFound }
    func messageHTML(id: String, loadRemoteImages: Bool) async throws -> MessageHTML { throw MailAPIError.notFound }
    func inlineImage(messageID: String, attachmentID: String) async throws -> BinaryPayload {
        throw MailAPIError.notFound
    }
    func attachmentData(id: String) async throws -> BinaryPayload { throw MailAPIError.notFound }
    func trustRemoteMedia(messageID: String) async throws { throw MailAPIError.notFound }
    /// The list `GET /drafts` answers with. `nil` (the default) means "whatever
    /// the in-memory drafts server holds", which is what the outbox tests want;
    /// the sync tests script it explicitly so the poll has something to diff.
    private var draftListing: [Draft]?
    private var draftListFailure: MailAPIError?

    func setDrafts(_ drafts: [Draft]) { draftListing = drafts }
    func setDraftListFailure(_ failure: MailAPIError?) { draftListFailure = failure }

    func listDrafts() async throws -> [Draft] {
        calls.append(.listDrafts)
        if let draftListFailure { throw draftListFailure }
        return draftListing ?? Array(storedDrafts.values)
    }

    // MARK: - Compose surface (P0.5)
    //
    // A small in-memory drafts server: ids, version stamps and 404s behave the
    // way the real one does, so the outbox tests exercise real save/send flows
    // rather than a stub that always says yes.

    private var storedDrafts: [String: Draft] = [:]
    private var draftSequence = 0
    private var forcedConflicts = 0
    private var sendFailure: MailAPIError?
    private var attachmentFailure: MailAPIError?
    private var sentSummary: MessageSummary?

    /// The next `n` PATCHes answer 409 the way upstream's `DRAFT_CONFLICT` does.
    func setForcedConflicts(_ count: Int) { forcedConflicts = count }
    func setSendFailure(_ failure: MailAPIError?) { sendFailure = failure }
    func setAttachmentFailure(_ failure: MailAPIError?) { attachmentFailure = failure }
    func setSentSummary(_ summary: MessageSummary?) { sentSummary = summary }
    func storedDraft(id: String) -> Draft? { storedDrafts[id] }
    func storedDraftCount() -> Int { storedDrafts.count }

    /// Simulates another session saving the draft (bumps the server version).
    func bumpStoredDraftVersion(id: String) {
        guard let draft = storedDrafts[id] else { return }
        storedDrafts[id] = Draft(
            id: draft.id,
            version: draft.version + 1,
            updatedAt: draft.updatedAt,
            attachments: draft.attachments,
            content: draft.content
        )
    }

    func draft(id: String) async throws -> Draft {
        calls.append(.fetchDraft(id))
        guard let draft = storedDrafts[id] else { throw MailAPIError.notFound }
        return draft
    }

    func createDraft(_ input: DraftInput) async throws -> Draft {
        calls.append(.createDraft(input))
        // Gated so a test can hold the one non-idempotent call open and prove a
        // second save really did arrive while it was in flight.
        await awaitGate()
        draftSequence += 1
        let draft = Draft(
            id: "drf_\(draftSequence)",
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 3_000),
            attachments: [],
            content: input
        )
        storedDrafts[draft.id] = draft
        return draft
    }

    func updateDraft(id: String, with input: DraftInput) async throws -> Draft {
        calls.append(.updateDraft(id: id, version: input.version))
        guard let existing = storedDrafts[id] else { throw MailAPIError.notFound }
        if forcedConflicts > 0 {
            forcedConflicts -= 1
            throw MailAPIError.server(code: "DRAFT_CONFLICT", message: "This draft changed in another session.")
        }
        guard input.version == existing.version else {
            throw MailAPIError.server(code: "DRAFT_CONFLICT", message: "This draft changed in another session.")
        }
        let updated = Draft(
            id: id,
            version: existing.version + 1,
            updatedAt: Date(timeIntervalSince1970: 3_100),
            attachments: existing.attachments,
            content: input
        )
        storedDrafts[id] = updated
        return updated
    }

    func deleteDraft(id: String) async throws {
        calls.append(.deleteDraft(id))
        guard storedDrafts.removeValue(forKey: id) != nil else { throw MailAPIError.notFound }
    }

    func addDraftAttachment(
        draftID: String,
        filename: String,
        mimeType: String,
        data: Data
    ) async throws -> DraftAttachment {
        calls.append(.addAttachment(draftID: draftID, filename: filename, bytes: data.count))
        if let attachmentFailure { throw attachmentFailure }
        guard let draft = storedDrafts[draftID] else { throw MailAPIError.notFound }
        let attachment = DraftAttachment(
            id: "att_\(draft.attachments.count + 1)",
            filename: filename,
            contentType: mimeType,
            sizeBytes: data.count
        )
        storedDrafts[draftID] = Draft(
            id: draft.id,
            version: draft.version,
            updatedAt: draft.updatedAt,
            attachments: draft.attachments + [attachment],
            content: draft.content
        )
        return attachment
    }

    func removeDraftAttachment(draftID: String, attachmentID: String) async throws {
        calls.append(.removeAttachment(draftID: draftID, attachmentID: attachmentID))
        guard let draft = storedDrafts[draftID],
              draft.attachments.contains(where: { $0.id == attachmentID })
        else { throw MailAPIError.notFound }
        storedDrafts[draftID] = Draft(
            id: draft.id,
            version: draft.version,
            updatedAt: draft.updatedAt,
            attachments: draft.attachments.filter { $0.id != attachmentID },
            content: draft.content
        )
    }

    func send(_ input: SendInput) async throws -> MessageSummary {
        calls.append(.sendMessage(input))
        if let sendFailure { throw sendFailure }
        return sentSummary ?? SyncFixtures.message("msg_sent", folder: .sent)
    }

    func reply(_ input: ReplyInput) async throws -> MessageSummary {
        calls.append(.replyToMessage(input))
        if let sendFailure { throw sendFailure }
        return sentSummary ?? SyncFixtures.message("msg_reply", folder: .sent)
    }
}

// MARK: - DTO builders

nonisolated enum SyncFixtures {
    static let account = "acct_1"

    static func mailbox(_ id: String) -> Mailbox {
        Mailbox(
            id: id,
            address: "\(id)@example.com",
            addresses: [],
            displayName: id,
            isActive: true,
            accessLevel: .manager,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    static func message(
        _ id: String,
        threadID: String = "thr_1",
        mailboxID: String? = "mbx_a",
        folder: MailFolder = .inbox,
        readAt: Date? = nil,
        starredAt: Date? = nil,
        subject: String = "Subject"
    ) -> MessageSummary {
        MessageSummary(
            id: id,
            threadID: threadID,
            mailboxID: mailboxID,
            direction: .inbound,
            folder: folder,
            fromAddress: "ada@example.net",
            to: ["support@example.com"],
            subject: subject,
            snippet: "…",
            receivedAt: Date(timeIntervalSince1970: 2_000),
            sentAt: nil,
            readAt: readAt,
            starredAt: starredAt,
            hasAttachments: false,
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
    }

    static func conversation(
        threadID: String,
        latestID: String = "msg_1",
        mailboxID: String? = "mbx_a",
        unreadCount: Int = 1
    ) -> ConversationSummary {
        ConversationSummary(
            latest: message(latestID, threadID: threadID, mailboxID: mailboxID),
            isStarred: false,
            messageCount: 1,
            unreadCount: unreadCount
        )
    }
}
