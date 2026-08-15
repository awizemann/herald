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
    var details: [String: MessageDetail] = [:]
    var html: [String: MessageHTML] = [:]

    func setActionError(_ error: MailAPIError?) { actionError = error }
    func setDetail(_ detail: MessageDetail) { details[detail.id] = detail }
    func setHTML(_ value: MessageHTML, for id: String) { html[id] = value }

    func actionCount(_ action: String, on id: String) -> Int {
        performed.count { $0.action == action && $0.id == id }
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

    func listMessages(folder: MailFolder?, mailboxID: String?, search: String?) async throws -> [MessageSummary] {
        []
    }

    func message(id: String) async throws -> MessageDetail {
        guard let detail = details[id] else { throw MailAPIError.notFound }
        return detail
    }

    func thread(messageID: String) async throws -> [MessageDetail] { [] }

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
        return MailFixtures.message(id: id)
    }

    func trustRemoteMedia(messageID: String) async throws { trusted.append(messageID) }

    func listConversations(
        folder: ConversationFolder?,
        mailboxID: String?,
        search: String?,
        cursor: String?
    ) async throws -> ConversationPage {
        ConversationPage(conversations: [], nextCursor: nil, totalCount: nil)
    }

    @discardableResult
    func perform(
        _ action: ConversationAction,
        onConversation id: String,
        in folder: ConversationFolder
    ) async throws -> ConversationActionResult {
        performed.append(PerformedAction(action: action.rawValue, id: id, folder: folder))
        if let actionError { throw actionError }
        return ConversationActionResult(threadID: id, affected: 1)
    }

    func listDrafts() async throws -> [Draft] { [] }
    func draft(id: String) async throws -> Draft { throw MailAPIError.notFound }
    func createDraft(_ input: DraftInput) async throws -> Draft { throw MailAPIError.notFound }
    func updateDraft(id: String, with input: DraftInput) async throws -> Draft { throw MailAPIError.notFound }
    func deleteDraft(id: String) async throws {}
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
        read: Bool = false,
        starred: Bool = false,
        date: Date = epoch
    ) -> MessageSummary {
        MessageSummary(
            id: id,
            threadID: threadID ?? "t-\(id)",
            mailboxID: mailboxID,
            direction: .inbound,
            folder: folder,
            fromAddress: "sender@example.com",
            to: ["team@example.com"],
            subject: subject,
            snippet: "snippet",
            receivedAt: date,
            sentAt: nil,
            readAt: read ? date : nil,
            starredAt: starred ? date : nil,
            hasAttachments: false,
            createdAt: date
        )
    }

    static func conversation(_ latest: MessageSummary, unread: Int = 1) -> ConversationSummary {
        ConversationSummary(
            latest: latest,
            isStarred: latest.isStarred,
            messageCount: 1,
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
