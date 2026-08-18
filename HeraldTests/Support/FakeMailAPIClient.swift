import Foundation
import HeraldKit

/// Records what the view-model asked the server to do and can be told to fail.
///
/// An actor (so it satisfies the `nonisolated protocol MailAPIClient` the same way
/// the production client does) and deliberately dumb: only the routes P0.4 uses
/// return anything interesting.
actor FakeMailAPIClient: MailAPIClient {
    struct PerformedAction: Sendable, Hashable {
        var action: String
        var id: String
        /// Conversation actions only. The server 400s without a folder, so "which
        /// folder did the view-model claim the thread was in" has to be observable.
        var folder: ConversationFolder?
    }

    /// Every sync pass starts with `listMailboxes`, so this counts polls.
    private(set) var mailboxRequestCount = 0
    private(set) var performed: [PerformedAction] = []
    private(set) var htmlRequests: [String] = []
    private(set) var trusted: [String] = []

    /// Set to make every `perform` fail, so the revert path can be driven.
    var actionError: MailAPIError?
    /// What a CONVERSATION action reports it changed. `0` is what the real server
    /// answers for an archive issued from Trash (upstream
    /// conversation-queries.ts:190-192) — a 200 that did nothing.
    var conversationAffected = 1
    var details: [String: MessageDetail] = [:]
    var html: [String: MessageHTML] = [:]

    func setActionError(_ error: MailAPIError?) { actionError = error }
    func setConversationAffected(_ affected: Int) { conversationAffected = affected }
    func setDetail(_ detail: MessageDetail) { details[detail.id] = detail }
    func setHTML(_ value: MessageHTML, for id: String) { html[id] = value }

    func actionCount(_ action: String, on id: String) -> Int {
        performed.count { $0.action == action && $0.id == id }
    }

    /// Conversation calls carry a folder, message calls never do — which route an
    /// action went down is the whole question in the Trash (issue #8).
    func conversationActionIDs(_ action: String) -> [String] {
        performed.filter { $0.action == action && $0.folder != nil }.map(\.id)
    }

    func messageActionIDs(_ action: String) -> [String] {
        performed.filter { $0.action == action && $0.folder == nil }.map(\.id)
    }

    /// The folders conversation actions were sent with, in order.
    func actionFolders(_ action: String, on id: String) -> [ConversationFolder?] {
        performed.filter { $0.action == action && $0.id == id }.map(\.folder)
    }

    // MARK: MailAPIClient

    func listMailboxes() async throws -> [Mailbox] {
        mailboxRequestCount += 1
        return []
    }

    func listMessages(
        folder: MailFolder?,
        mailboxID: String?,
        search: String?,
        limit: Int?,
        cursor: String?
    ) async throws -> MessagePage {
        MessagePage(messages: [], nextCursor: nil)
    }

    /// The app suites run against a pre-journal server: `.notFound` is what makes
    /// the engine take the legacy full-listing path, which is what they assert on.
    func changes(cursor: String?, limit: Int?) async throws -> ChangePage {
        throw MailAPIError.notFound
    }

    func message(id: String) async throws -> MessageDetail {
        guard let detail = details[id] else { throw MailAPIError.notFound }
        return detail
    }

    private var threads: [String: [MessageDetail]] = [:]

    func setThread(_ details: [MessageDetail], forMessage id: String) { threads[id] = details }

    func thread(messageID: String) async throws -> [MessageDetail] { threads[messageID] ?? [] }

    func messageHTML(id: String, loadRemoteImages: Bool) async throws -> MessageHTML {
        htmlRequests.append(id)
        guard let value = html[id] else { throw MailAPIError.notFound }
        return value
    }

    func inlineImage(messageID: String, attachmentID: String) async throws -> BinaryPayload {
        BinaryPayload(data: Data([0x89, 0x50]), mimeType: "image/png")
    }

    func attachmentData(id: String) async throws -> BinaryPayload {
        BinaryPayload(data: Data("file".utf8), mimeType: "text/plain")
    }

    @discardableResult
    func perform(_ action: MessageAction, onMessage id: String) async throws -> MessageSummary {
        performed.append(PerformedAction(action: action.rawValue, id: id))
        if let actionError { throw actionError }
        // The real server answers with the UPDATED summary, and `MailActionService`
        // now writes it back as authoritative. A stub that ignored the action made
        // every successful mark-read look like a server that refused it.
        let base = details[id]?.summary ?? MailFixtures.message(id: id)
        return Self.applying(action, to: base)
    }

    /// The action applied to the summary the way the server applies it, so the
    /// answer describes the row the client just changed rather than a fresh stub.
    private nonisolated static func applying(
        _ action: MessageAction,
        to summary: MessageSummary
    ) -> MessageSummary {
        let now = MailFixtures.epoch
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

    func trustRemoteMedia(messageID: String) async throws { trusted.append(messageID) }

    /// One `GET /conversations` as the view-model asked for it.
    struct ConversationQuery: Sendable, Hashable {
        var folder: ConversationFolder?
        var mailboxID: String?
        var search: String?
        var cursor: String?
    }

    private(set) var conversationQueries: [ConversationQuery] = []
    /// Pages keyed by the cursor that asks for them; `""` is the first page.
    private var conversationPages: [String: ConversationPage] = [:]
    private var conversationError: MailAPIError?

    func setConversationPage(_ page: ConversationPage, forCursor cursor: String? = nil) {
        conversationPages[cursor ?? ""] = page
    }

    func setConversationError(_ error: MailAPIError?) { conversationError = error }

    func searches() -> [ConversationQuery] { conversationQueries.filter { $0.search != nil } }

    // MARK: Gate

    /// Holds every `listConversations` call until the gate is opened again — the
    /// only way to have a search genuinely IN FLIGHT while the test changes the
    /// query underneath it, without sleeping on a timer.
    private var gateIsOpen = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func closeConversationGate() { gateIsOpen = false }

    func openConversationGate() {
        gateIsOpen = true
        let resuming = waiters
        waiters = []
        for waiter in resuming { waiter.resume() }
    }

    /// Resolves once at least `count` calls are parked at the closed gate, so a
    /// test can wait for the request to have STARTED without sleeping.
    func waitForPendingSearch(count: Int = 1) async {
        // Bounded: a test that mis-wires the gate should fail on its assertion,
        // not hang the suite forever.
        for _ in 0..<10_000 {
            if waiters.count >= count { return }
            await Task.yield()
        }
    }

    private func passGate() async {
        guard !gateIsOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func listConversations(
        folder: ConversationFolder?,
        mailboxID: String?,
        search: String?,
        cursor: String?
    ) async throws -> ConversationPage {
        conversationQueries.append(
            ConversationQuery(folder: folder, mailboxID: mailboxID, search: search, cursor: cursor)
        )
        await passGate()
        if let conversationError { throw conversationError }
        return conversationPages[cursor ?? ""]
            ?? ConversationPage(conversations: [], nextCursor: nil, totalCount: nil)
    }

    @discardableResult
    func perform(
        _ action: ConversationAction,
        onConversation id: String,
        in folder: ConversationFolder
    ) async throws -> ConversationActionResult {
        performed.append(PerformedAction(action: action.rawValue, id: id, folder: folder))
        if let actionError { throw actionError }
        return ConversationActionResult(threadID: id, affected: conversationAffected)
    }

    // MARK: Drafts
    //
    // Recorded, not stubbed away: "the composer was seeded from the CACHE" is
    // only assertable if a network fetch would have been visible.

    private(set) var deletedDraftIDs: [String] = []
    private(set) var fetchedDraftIDs: [String] = []
    private var draftDeleteError: MailAPIError?

    func setDraftDeleteError(_ error: MailAPIError?) { draftDeleteError = error }

    func listDrafts() async throws -> [Draft] { [] }
    func draft(id: String) async throws -> Draft {
        fetchedDraftIDs.append(id)
        throw MailAPIError.notFound
    }
    func createDraft(_ input: DraftInput) async throws -> Draft { throw MailAPIError.notFound }
    func updateDraft(id: String, with input: DraftInput) async throws -> Draft { throw MailAPIError.notFound }
    func deleteDraft(id: String) async throws {
        deletedDraftIDs.append(id)
        if let draftDeleteError { throw draftDeleteError }
    }
    func addDraftAttachment(
        draftID: String,
        filename: String,
        mimeType: String,
        data: Data
    ) async throws -> DraftAttachment {
        throw MailAPIError.notFound
    }
    func removeDraftAttachment(draftID: String, attachmentID: String) async throws {}
    func send(_ input: SendInput) async throws -> MessageSummary { throw MailAPIError.notFound }
    func reply(_ input: ReplyInput) async throws -> MessageSummary { throw MailAPIError.notFound }
}

/// Minimal DTO builders for the app-hosted suites.
nonisolated enum MailFixtures {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func message(
        id: String,
        threadID: String? = nil,
        mailboxID: String? = "mbA",
        folder: MailFolder = .inbox,
        subject: String = "Subject",
        from: String = "sender@example.com",
        to: [String] = ["team@example.com"],
        snippet: String = "snippet",
        read: Bool = false,
        starred: Bool = false,
        hasAttachments: Bool = false,
        date: Date = epoch
    ) -> MessageSummary {
        MessageSummary(
            id: id,
            threadID: threadID ?? "t-\(id)",
            mailboxID: mailboxID,
            direction: .inbound,
            folder: folder,
            fromAddress: from,
            to: to,
            subject: subject,
            snippet: snippet,
            receivedAt: date,
            sentAt: nil,
            readAt: read ? date : nil,
            starredAt: starred ? date : nil,
            hasAttachments: hasAttachments,
            createdAt: date
        )
    }

    static func conversation(
        _ latest: MessageSummary,
        unread: Int = 1,
        messageCount: Int = 1
    ) -> ConversationSummary {
        ConversationSummary(
            latest: latest,
            isStarred: latest.isStarred,
            messageCount: messageCount,
            unreadCount: unread
        )
    }

    static func detail(_ summary: MessageSummary, htmlAvailable: Bool = true) -> MessageDetail {
        MessageDetail(
            summary: summary,
            cc: [],
            bcc: [],
            deliveredToAddress: nil,
            textBody: "text body",
            htmlAvailable: htmlAvailable,
            rfcMessageID: nil,
            inReplyTo: nil,
            references: [],
            attachments: []
        )
    }
}
