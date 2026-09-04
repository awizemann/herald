import Foundation
import HTTPTypes
import HeraldAPI
import OpenAPIRuntime
import OpenAPIURLSession

/// Talks to one HQBase origin's Mail API v1.
///
/// An actor so sync/compose can call it off the main actor; everything it returns
/// is a Sendable DTO. Generated `HeraldAPI` types never escape this file or
/// `Mapping.swift`.
public actor HQBaseAPIClient: MailAPIClient {
    private let client: HeraldAPI.Client

    /// - Parameters:
    ///   - origin: the account's server origin, e.g. `https://mail.example.com`.
    ///   - tokens: supplies and refreshes the OAuth access token.
    ///   - session: injected in tests so `FakeServer` can answer requests.
    public init(origin: URL, tokens: any BearerTokenProvider, session: URLSession = .shared) {
        self.client = HeraldAPI.Client(
            serverURL: origin,
            configuration: .init(dateTranscoder: HQBaseDateTranscoder()),
            transport: URLSessionTransport(configuration: .init(session: session)),
            middlewares: [AuthenticatingMiddleware(tokens: tokens)]
        )
    }

    /// Funnels every generated error into ``MailAPIError``.
    private func perform<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch {
            throw MailAPIError.mapping(error)
        }
    }

    /// Reached only if the server answers with a 2xx status the spec does not document
    /// (the middleware has already rejected everything >= 400).
    private nonisolated func unexpected(_ statusCode: Int) -> MailAPIError {
        .server(code: "unexpected_response", message: "Unexpected HTTP \(statusCode)")
    }

    /// Unreachable: `AuthenticatingMiddleware` throws before the generated client
    /// can decode a documented error response. Present only for exhaustiveness.
    private nonisolated var unhandledErrorResponse: MailAPIError {
        .server(code: "unexpected_response", message: "Unhandled error response")
    }

    // MARK: - Mailboxes

    public func listMailboxes() async throws -> [Mailbox] {
        try await perform {
            switch try await client.listMailboxes(.init()) {
            case .ok(let ok): return try ok.body.json.map(Mailbox.init)
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    // MARK: - Messages

    public func listMessages(
        folder: MailFolder?,
        mailboxID: String?,
        search: String?,
        limit: Int?,
        cursor: String?
    ) async throws -> MessagePage {
        try await perform {
            let query = Operations.ListMessages.Input.Query(
                folder: folder.flatMap { .init(rawValue: $0.rawValue) },
                mailboxId: mailboxID,
                search: search,
                limit: limit,
                cursor: cursor
            )
            switch try await client.listMessages(.init(query: query)) {
            case .ok(let ok):
                return MessagePage(
                    messages: try ok.body.json.map(MessageSummary.init),
                    // Absent on the last page, and on every pre-pagination server.
                    nextCursor: LinkHeader.nextCursor(from: ok.headers.link)
                )
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    // MARK: - Changes

    public func changes(cursor: String?, limit: Int?) async throws -> ChangePage {
        try await perform {
            let query = Operations.ListMessageChanges.Input.Query(cursor: cursor, limit: limit)
            switch try await client.listMessageChanges(.init(query: query)) {
            case .ok(let ok): return try ChangePage(ok.body.json)
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    public func message(id: String) async throws -> MessageDetail {
        try await perform {
            switch try await client.getMessage(.init(path: .init(id: id))) {
            case .ok(let ok): return try MessageDetail(ok.body.json)
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    public func thread(messageID: String) async throws -> [MessageDetail] {
        try await perform {
            switch try await client.getMessageThread(.init(path: .init(id: messageID))) {
            case .ok(let ok): return try ok.body.json.map(MessageDetail.init)
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    public func messageHTML(id: String, loadRemoteImages: Bool) async throws -> MessageHTML {
        try await perform {
            let input = Operations.GetMessageHtml.Input(
                path: .init(id: id),
                query: .init(loadRemoteImages: loadRemoteImages ? ._1 : nil)
            )
            switch try await client.getMessageHtml(input) {
            case .ok(let ok): return try MessageHTML(ok.body.json)
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    public func inlineImage(messageID: String, attachmentID: String) async throws -> BinaryPayload {
        try await perform {
            let input = Operations.GetInlineAttachment.Input(path: .init(id: messageID, attachmentId: attachmentID))
            switch try await client.getInlineAttachment(input) {
            case .ok(let ok):
                let data = try await Self.collect(ok.body.image_Ast_)
                return BinaryPayload(data: data, mimeType: MIMESniffer.imageType(of: data))
            case .undocumented(let code, _):
                throw unexpected(code)
            default:
                throw unhandledErrorResponse
            }
        }
    }

    public func attachmentData(id: String) async throws -> BinaryPayload {
        try await perform {
            switch try await client.getAttachment(.init(path: .init(id: id))) {
            case .ok(let ok):
                let data = try await Self.collect(ok.body.binary)
                // The generated client does not surface the response's
                // `Content-Type` for this route, and the hardcoded
                // `application/octet-stream` that used to sit here staged every
                // download as `.dat` — Quick Look picks its previewer from the
                // extension alone, so nothing previewed. Sniff the bytes; the
                // caller crosses this with the server's `Attachment.contentType`.
                return BinaryPayload(data: data, mimeType: MIMESniffer.sniff(data) ?? MIMESniffer.unknownType)
            case .undocumented(let code, _):
                throw unexpected(code)
            default:
                throw unhandledErrorResponse
            }
        }
    }

    @discardableResult
    public func perform(_ action: MessageAction, onMessage id: String) async throws -> MessageSummary {
        try await perform {
            guard let generatedAction = Operations.UpdateMessage.Input.Path.ActionPayload(rawValue: action.rawValue) else {
                throw MailAPIError.server(code: "unsupported_action", message: action.rawValue)
            }
            switch try await client.updateMessage(.init(path: .init(id: id, action: generatedAction))) {
            case .ok(let ok): return try MessageSummary(ok.body.json)
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    public func trustRemoteMedia(messageID: String) async throws {
        try await perform {
            switch try await client.trustRemoteMedia(.init(path: .init(id: messageID))) {
            case .ok: return
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    // MARK: - Conversations

    public func listConversations(
        folder: ConversationFolder?,
        mailboxID: String?,
        search: String?,
        cursor: String?
    ) async throws -> ConversationPage {
        try await perform {
            let query = Operations.ListConversations.Input.Query(
                folder: folder.flatMap { .init(rawValue: $0.rawValue) },
                mailboxId: mailboxID,
                search: search,
                cursor: cursor
            )
            switch try await client.listConversations(.init(query: query)) {
            case .ok(let ok): return try ConversationPage(ok.body.json)
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    @discardableResult
    public func perform(
        _ action: ConversationAction,
        onConversation id: String,
        in folder: ConversationFolder
    ) async throws -> ConversationActionResult {
        try await perform {
            guard
                let generatedAction = Operations.UpdateConversation.Input.Path.ActionPayload(rawValue: action.rawValue),
                let generatedFolder = Components.Schemas.ConversationActionInput.FolderPayload(rawValue: folder.rawValue)
            else {
                throw MailAPIError.server(code: "unsupported_action", message: action.rawValue)
            }
            let input = Operations.UpdateConversation.Input(
                path: .init(id: id, action: generatedAction),
                body: .json(.init(folder: generatedFolder))
            )
            switch try await client.updateConversation(input) {
            case .ok(let ok): return try ConversationActionResult(ok.body.json)
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    // MARK: - Drafts

    public func listDrafts() async throws -> [Draft] {
        try await perform {
            switch try await client.listDrafts(.init()) {
            case .ok(let ok): return try ok.body.json.map(Draft.init)
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    public func draft(id: String) async throws -> Draft {
        try await perform {
            switch try await client.getDraft(.init(path: .init(id: id))) {
            case .ok(let ok): return try Draft(ok.body.json)
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    public func createDraft(_ input: DraftInput) async throws -> Draft {
        try await perform {
            switch try await client.createDraft(.init(body: .json(input.generated))) {
            case .created(let created): return try Draft(created.body.json)
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    public func updateDraft(id: String, with input: DraftInput) async throws -> Draft {
        try await perform {
            switch try await client.updateDraft(.init(path: .init(id: id), body: .json(input.generated))) {
            case .ok(let ok): return try Draft(ok.body.json)
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    public func deleteDraft(id: String) async throws {
        try await perform {
            switch try await client.deleteDraft(.init(path: .init(id: id))) {
            case .noContent: return
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    public func addDraftAttachment(
        draftID: String,
        filename: String,
        mimeType: String,
        data: Data
    ) async throws -> DraftAttachment {
        try await perform {
            // Upstream 1.3.4 honours a per-part Content-Type (their #45), and the
            // spec declares `encoding.file.contentType: "*/*"` — but the generator
            // burns that literal `*/*` into the typed `.file` case, so the typed
            // payload can only ever send `*/*` and the server falls back to
            // sniffing. The raw part is the only way to state the real type; the
            // operation allows unknown parts, and the name/filename here are
            // exactly what the typed case would have produced.
            var partHeaders = HTTPFields()
            partHeaders[.contentType] = mimeType
            let raw = MultipartRawPart(
                name: "file",
                filename: filename,
                headerFields: partHeaders,
                body: HTTPBody([UInt8](data))
            )
            let input = Operations.AddDraftAttachment.Input(
                path: .init(id: draftID),
                body: .multipartForm(.init([.undocumented(raw)]))
            )
            switch try await client.addDraftAttachment(input) {
            case .created(let created): return try DraftAttachment(created.body.json)
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    public func removeDraftAttachment(draftID: String, attachmentID: String) async throws {
        try await perform {
            switch try await client.removeDraftAttachment(.init(path: .init(draftId: draftID, id: attachmentID))) {
            case .noContent: return
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    // MARK: - Signatures

    public func signatures(from address: String) async throws -> SignatureCandidates {
        try await perform {
            switch try await client.listSignatures(.init(query: .init(from: address))) {
            case .ok(let ok): return try SignatureCandidates(ok.body.json)
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    // MARK: - Sending

    public func send(_ input: SendInput) async throws -> MessageSummary {
        try await perform {
            switch try await client.sendMessage(.init(body: .json(input.generated))) {
            case .created(let created): return try MessageSummary(created.body.json)
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    public func forward(_ input: ForwardInput) async throws -> MessageSummary {
        try await perform {
            switch try await client.forwardMessage(.init(body: .json(input.generated))) {
            case .created(let created): return try MessageSummary(created.body.json)
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    public func reply(_ input: ReplyInput) async throws -> MessageSummary {
        try await perform {
            switch try await client.replyToMessage(.init(body: .json(input.generated))) {
            case .created(let created): return try MessageSummary(created.body.json)
            case .undocumented(let code, _): throw unexpected(code)
            default: throw unhandledErrorResponse
            }
        }
    }

    // MARK: - Helpers

    private static let maxBinaryBytes = 64 * 1024 * 1024

    private static func collect(_ body: HTTPBody) async throws -> Data {
        try await Data([UInt8](collecting: body, upTo: maxBinaryBytes))
    }
}
