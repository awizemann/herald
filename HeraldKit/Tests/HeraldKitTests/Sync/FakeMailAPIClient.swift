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
        case listMessages(folder: MailFolder?, mailboxID: String?)
        case performMessage(MessageAction, String)
        case performConversation(ConversationAction, String, ConversationFolder)
    }

    private(set) var calls: [Call] = []

    // MARK: Script
    private var mailboxes: [Mailbox] = []
    /// Conversation pages keyed by the cursor that requests them ("" = first page).
    private var conversationPages: [String: ConversationPage] = [:]
    private var messagesByFolder: [MailFolder: [MessageSummary]] = [:]
    private var listFailure: MailAPIError?
    private var actionFailure: MailAPIError?

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

    func setListFailure(_ failure: MailAPIError?) { listFailure = failure }
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

    func listMessages(folder: MailFolder?, mailboxID: String?, search: String?) async throws -> [MessageSummary] {
        calls.append(.listMessages(folder: folder, mailboxID: mailboxID))
        if let listFailure { throw listFailure }
        guard let folder else { return messagesByFolder.values.flatMap { $0 } }
        let messages = messagesByFolder[folder] ?? []
        guard let mailboxID else { return messages }
        return messages.filter { $0.mailboxID == mailboxID }
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

    @discardableResult
    func perform(_ action: MessageAction, onMessage id: String) async throws -> MessageSummary {
        calls.append(.performMessage(action, id))
        if let actionFailure { throw actionFailure }
        throw MailAPIError.notFound
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
    func listDrafts() async throws -> [Draft] { throw MailAPIError.notFound }
    func draft(id: String) async throws -> Draft { throw MailAPIError.notFound }
    func createDraft(_ input: DraftInput) async throws -> Draft { throw MailAPIError.notFound }
    func updateDraft(id: String, with input: DraftInput) async throws -> Draft { throw MailAPIError.notFound }
    func deleteDraft(id: String) async throws { throw MailAPIError.notFound }
    func addDraftAttachment(
        draftID: String,
        filename: String,
        mimeType: String,
        data: Data
    ) async throws -> DraftAttachment { throw MailAPIError.notFound }
    func removeDraftAttachment(draftID: String, attachmentID: String) async throws { throw MailAPIError.notFound }
    func send(_ input: SendInput) async throws -> MessageSummary { throw MailAPIError.notFound }
    func reply(_ input: ReplyInput) async throws -> MessageSummary { throw MailAPIError.notFound }
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
