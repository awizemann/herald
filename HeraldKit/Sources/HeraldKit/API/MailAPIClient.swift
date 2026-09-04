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
    /// One page of messages. `limit`/`cursor` are ignored by servers older than
    /// the pagination release, which answer with the whole (capped) list and no
    /// `Link` header — so `nextCursor` comes back `nil` there.
    func listMessages(
        folder: MailFolder?,
        mailboxID: String?,
        search: String?,
        limit: Int?,
        cursor: String?
    ) async throws -> MessagePage
    func message(id: String) async throws -> MessageDetail
    func thread(messageID: String) async throws -> [MessageDetail]
    func messageHTML(id: String, loadRemoteImages: Bool) async throws -> MessageHTML
    func inlineImage(messageID: String, attachmentID: String) async throws -> BinaryPayload
    func attachmentData(id: String) async throws -> BinaryPayload
    @discardableResult
    func perform(_ action: MessageAction, onMessage id: String) async throws -> MessageSummary
    /// Marks the sender trusted so remote media loads for this message from now on.
    func trustRemoteMedia(messageID: String) async throws

    // MARK: Labels
    /// Every workspace label. Requires a server at upstream 1.3.4 or newer; older
    /// ones answer 404.
    func listLabels() async throws -> [MailLabel]
    /// One page of the messages carrying `labelID`, across every folder and every
    /// readable mailbox.
    ///
    /// This is the ONLY way to learn which messages carry a label on the v1 API:
    /// v1 message, conversation and change payloads have no `labels` field (the
    /// server gates the embed on `/api/v2` — `includeLabels` in
    /// `worker/features/messages/routes.ts`), so membership is derived by
    /// filtering, not read off the row.
    func listMessages(labelID: String, limit: Int?, cursor: String?) async throws -> MessagePage
    /// Adds (`assigned: true`) or removes one label on one message.
    @discardableResult
    func setLabel(_ labelID: String, onMessage id: String, assigned: Bool) async throws -> LabelAssignment
    /// Same for a whole thread. `id` is a MESSAGE id representing the
    /// conversation, exactly like the conversation action routes.
    @discardableResult
    func setLabel(_ labelID: String, onConversation id: String, assigned: Bool) async throws -> LabelAssignment

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

    // MARK: Changes
    /// The durable change journal. A `nil` cursor is a CHECKPOINT request: it
    /// returns no history, only the journal's current high-water cursor.
    ///
    /// Throws ``MailAPIError/cursorExpired`` when the journal no longer covers
    /// the cursor (re-bootstrap), and ``MailAPIError/notFound`` on a server that
    /// predates the endpoint (fall back to full listing).
    func changes(cursor: String?, limit: Int?) async throws -> ChangePage

    // MARK: Drafts
    func listDrafts() async throws -> [Draft]
    func draft(id: String) async throws -> Draft
    func createDraft(_ input: DraftInput) async throws -> Draft
    func updateDraft(id: String, with input: DraftInput) async throws -> Draft
    func deleteDraft(id: String) async throws
    func addDraftAttachment(draftID: String, filename: String, mimeType: String, data: Data) async throws -> DraftAttachment
    func removeDraftAttachment(draftID: String, attachmentID: String) async throws

    // MARK: Signatures
    /// Signatures usable from this EXACT sending address, plus the id the
    /// `automatic` selection resolves to. Requires a server at upstream 1.3.4 or
    /// newer; older ones answer 404.
    func signatures(from address: String) async throws -> SignatureCandidates

    // MARK: Sending
    func send(_ input: SendInput) async throws -> MessageSummary
    func reply(_ input: ReplyInput) async throws -> MessageSummary
    /// `POST /forward` — the only send path that preserves the forwarded
    /// original. Requires a server at upstream 1.3.4 or newer.
    func forward(_ input: ForwardInput) async throws -> MessageSummary
}

nonisolated extension MailAPIClient {
    /// Convenience for callers that want one (server-capped) page as a bare
    /// array — search, and any listing small enough that paging is pointless.
    public func listMessages(
        folder: MailFolder? = nil,
        mailboxID: String? = nil,
        search: String? = nil
    ) async throws -> [MessageSummary] {
        try await listMessages(folder: folder, mailboxID: mailboxID, search: search, limit: nil, cursor: nil).messages
    }

    /// Convenience: a fresh checkpoint at the journal's current high-water mark.
    public func changesCheckpoint() async throws -> ChangePage {
        try await changes(cursor: nil, limit: nil)
    }

    /// Convenience: first page of a folder's conversations.
    public func listConversations(folder: ConversationFolder?, cursor: String? = nil) async throws -> ConversationPage {
        try await listConversations(folder: folder, mailboxID: nil, search: nil, cursor: cursor)
    }

    public func messageHTML(id: String) async throws -> MessageHTML {
        try await messageHTML(id: id, loadRemoteImages: false)
    }
}
