import Foundation

/// Supplies (and refreshes) the OAuth access token for one account.
///
/// `nonisolated` so an actor — and a test fake actor — can conform under the
/// package's default-MainActor isolation.
public nonisolated protocol BearerTokenProvider: Sendable {
    /// The current access token, minting one if necessary.
    func accessToken() async throws -> String
    /// Exchanges the refresh token for a new access token and returns it.
    ///
    /// `failedToken` is the access token the caller actually sent and got a 401
    /// for. If the stored token has already moved on (a concurrent request
    /// refreshed while this one was in flight) the stored one is returned as-is:
    /// refreshing again would redeem an already-rotated grant and sign the
    /// account out.
    func refreshAccessToken(failedToken: String) async throws -> String
}

/// Binary payload plus the MIME type the caller needs to render or save it.
public nonisolated struct BinaryPayload: Sendable, Hashable {
    public let data: Data
    public let mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

/// Every HQBase Mail API v1 operation, in DTO terms.
///
/// The whole app codes against this; ``HQBaseAPIClient`` is the only production
/// implementation and tests inject fakes. All methods throw ``MailAPIError``.
public nonisolated protocol MailAPIClient: Sendable {
    // MARK: Mailboxes
    func listMailboxes() async throws -> [Mailbox]

    // MARK: Messages
    func listMessages(folder: MailFolder?, mailboxID: String?, search: String?) async throws -> [MessageSummary]
    func message(id: String) async throws -> MessageDetail
    func thread(messageID: String) async throws -> [MessageDetail]
    func messageHTML(id: String, loadRemoteImages: Bool) async throws -> MessageHTML
    func inlineImage(messageID: String, attachmentID: String) async throws -> BinaryPayload
    func attachmentData(id: String) async throws -> BinaryPayload
    @discardableResult
    func perform(_ action: MessageAction, onMessage id: String) async throws -> MessageSummary
    /// Marks the sender trusted so remote media loads for this message from now on.
    func trustRemoteMedia(messageID: String) async throws

    // MARK: Conversations
    func listConversations(
        folder: ConversationFolder?,
        mailboxID: String?,
        search: String?,
        cursor: String?
    ) async throws -> ConversationPage
    @discardableResult
    func perform(
        _ action: ConversationAction,
        onConversation id: String,
        in folder: ConversationFolder
    ) async throws -> ConversationActionResult

    // MARK: Drafts
    func listDrafts() async throws -> [Draft]
    func draft(id: String) async throws -> Draft
    func createDraft(_ input: DraftInput) async throws -> Draft
    func updateDraft(id: String, with input: DraftInput) async throws -> Draft
    func deleteDraft(id: String) async throws
    func addDraftAttachment(draftID: String, filename: String, mimeType: String, data: Data) async throws -> DraftAttachment
    func removeDraftAttachment(draftID: String, attachmentID: String) async throws

    // MARK: Sending
    func send(_ input: SendInput) async throws -> MessageSummary
    func reply(_ input: ReplyInput) async throws -> MessageSummary
}

nonisolated extension MailAPIClient {
    /// Convenience for the common unfiltered listing.
    public func listMessages(folder: MailFolder? = nil, mailboxID: String? = nil) async throws -> [MessageSummary] {
        try await listMessages(folder: folder, mailboxID: mailboxID, search: nil)
    }

    /// Convenience: first page of a folder's conversations.
    public func listConversations(folder: ConversationFolder?, cursor: String? = nil) async throws -> ConversationPage {
        try await listConversations(folder: folder, mailboxID: nil, search: nil, cursor: cursor)
    }

    public func messageHTML(id: String) async throws -> MessageHTML {
        try await messageHTML(id: id, loadRemoteImages: false)
    }
}
