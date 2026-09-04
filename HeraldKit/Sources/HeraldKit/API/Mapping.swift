import Foundation
import HeraldAPI
import OpenAPIRuntime

/// The ONE place generated `HeraldAPI` types are converted to HeraldKit DTOs.
/// Nothing outside this file and `HQBaseAPIClient.swift` may import `HeraldAPI`;
/// `SourceBoundaryTests` enforces that.

// MARK: - Generated → DTO

nonisolated extension MailboxAddress {
    init(_ generated: Components.Schemas.MailboxAddress) {
        self.init(
            id: generated.id,
            mailboxID: generated.mailboxId,
            mailDomainID: generated.mailDomainId,
            address: generated.address,
            displayName: generated.displayName,
            receiveEnabled: generated.receiveEnabled,
            sendEnabled: generated.sendEnabled,
            isPrimary: generated.isPrimary
        )
    }
}

nonisolated extension Mailbox {
    init(_ generated: Components.Schemas.Mailbox) {
        self.init(
            id: generated.id,
            address: generated.address,
            addresses: generated.addresses.map(MailboxAddress.init),
            displayName: generated.displayName,
            isActive: generated.isActive,
            accessLevel: generated.accessLevel.flatMap { MailboxAccessLevel(rawValue: $0.rawValue) },
            createdAt: generated.createdAt,
            updatedAt: generated.updatedAt
        )
    }
}

nonisolated extension MessageSummary {
    init(_ generated: Components.Schemas.MessageSummary) {
        self.init(
            id: generated.id,
            threadID: generated.threadId,
            mailboxID: generated.mailboxId,
            direction: MessageDirection(rawValue: generated.direction.rawValue) ?? .inbound,
            folder: MailFolder(rawValue: generated.folder.rawValue) ?? .inbox,
            fromAddress: generated.fromAddress,
            to: generated.to,
            subject: generated.subject,
            snippet: generated.snippet,
            receivedAt: generated.receivedAt,
            sentAt: generated.sentAt,
            readAt: generated.readAt,
            starredAt: generated.starredAt,
            hasAttachments: generated.hasAttachments,
            createdAt: generated.createdAt
        )
    }
}

nonisolated extension MessageChange {
    /// The generated `oneOf` names its cases after the schemas, and the decoder
    /// tries them in declaration order — so the discriminator (`type`) is what
    /// actually separates them, not the case name.
    init(_ generated: Components.Schemas.MessageChange) {
        switch generated {
        case .MessageChangeUpsert(let upsert):
            self = .upsert(MessageSummary(upsert.message))
        case .MessageChangeDelete(let delete):
            self = .delete(messageID: delete.messageId, mailboxID: delete.mailboxId)
        }
    }
}

nonisolated extension ChangePage {
    init(_ generated: Components.Schemas.MessageChangePage) {
        self.init(
            changes: generated.changes.map(MessageChange.init),
            nextCursor: generated.nextCursor,
            hasMore: generated.hasMore
        )
    }
}

nonisolated extension Attachment {
    init(_ generated: Components.Schemas.Attachment) {
        self.init(
            id: generated.id,
            messageID: generated.messageId,
            filename: generated.filename,
            contentType: generated.contentType,
            sizeBytes: generated.sizeBytes,
            contentID: generated.contentId,
            disposition: AttachmentDisposition(rawValue: generated.disposition.rawValue) ?? .attachment,
            createdAt: generated.createdAt
        )
    }
}

nonisolated extension MessageDetail {
    init(_ generated: Components.Schemas.MessageDetail) {
        let extra = generated.value2
        self.init(
            summary: MessageSummary(generated.value1),
            cc: extra.cc,
            bcc: extra.bcc,
            deliveredToAddress: extra.deliveredToAddress,
            textBody: extra.textBody,
            htmlAvailable: extra.htmlAvailable,
            rfcMessageID: extra.messageId,
            inReplyTo: extra.inReplyTo,
            references: extra.references,
            attachments: extra.attachments.map(Attachment.init)
        )
    }
}

nonisolated extension MessageHTML {
    init(_ generated: Components.Schemas.MessageHtml) {
        self.init(
            html: generated.html,
            quotedHTML: generated.quotedHtml,
            afterQuotedHTML: generated.afterQuotedHtml,
            hasRemoteImages: generated.hasRemoteImages,
            htmlHasRemoteImages: generated.htmlHasRemoteImages,
            quotedHTMLHasRemoteImages: generated.quotedHtmlHasRemoteImages,
            afterQuotedHTMLHasRemoteImages: generated.afterQuotedHtmlHasRemoteImages,
            remoteMediaTrusted: generated.remoteMediaTrusted
        )
    }
}

nonisolated extension ConversationSummary {
    init(_ generated: Components.Schemas.ConversationSummary) {
        self.init(
            latest: MessageSummary(generated.value1),
            isStarred: generated.value2.isStarred,
            messageCount: generated.value2.messageCount,
            unreadCount: generated.value2.unreadCount
        )
    }
}

nonisolated extension ConversationPage {
    init(_ generated: Components.Schemas.ConversationPage) {
        self.init(
            conversations: generated.conversations.map(ConversationSummary.init),
            nextCursor: generated.nextCursor,
            totalCount: generated.totalCount
        )
    }
}

nonisolated extension ConversationActionResult {
    init(_ generated: Components.Schemas.ConversationActionResult) {
        self.init(threadID: generated.threadId, affected: generated.affected)
    }
}

nonisolated extension DraftAttachment {
    init(_ generated: Components.Schemas.DraftAttachment) {
        self.init(
            id: generated.id,
            filename: generated.filename,
            contentType: generated.contentType,
            sizeBytes: generated.sizeBytes
        )
    }
}

nonisolated extension SignatureScope {
    init?(_ generated: Components.Schemas.Signature.ScopePayload) {
        self.init(rawValue: generated.rawValue)
    }
}

nonisolated extension Signature {
    init(_ generated: Components.Schemas.Signature) {
        self.init(
            id: generated.id,
            name: generated.name,
            html: generated.html,
            text: generated.text,
            // A scope Herald does not know cannot be resolved into anything
            // sensible, and `user` is the least surprising label to show.
            scope: SignatureScope(generated.scope) ?? .user,
            scopeID: generated.scopeId,
            scopeLabel: generated.scopeLabel,
            isDefault: generated.isDefault,
            createdAt: generated.createdAt,
            updatedAt: generated.updatedAt
        )
    }
}

nonisolated extension SignatureCandidates {
    init(_ generated: Components.Schemas.SignatureCandidates) {
        self.init(
            automaticSignatureID: generated.automaticSignatureId,
            signatures: generated.signatures.map(Signature.init)
        )
    }
}

nonisolated extension SignatureSnapshot {
    init(_ generated: Components.Schemas.SignatureSnapshot) {
        self.init(
            mode: Mode(rawValue: generated.mode.rawValue) ?? .none,
            id: generated.id,
            name: generated.name,
            html: generated.html,
            text: generated.text
        )
    }
}

nonisolated extension SignatureSelection {
    /// The generated `oneOf` has no discriminator, so the payload's `mode`
    /// literal is what separates the cases — the case NUMBER is meaningless.
    var generated: Components.Schemas.SignatureSelection {
        switch self {
        case .automatic: return .case1(.init(mode: .automatic))
        case .selected(let id): return .case2(.init(mode: .selected, id: id))
        case .noSignature: return .case3(.init(mode: .none))
        }
    }
}

nonisolated extension DraftInput {
    /// From a STORED draft's fields. `DraftFields` is `DraftInput` minus the
    /// write-only `signature` selection (see the schema's own note in
    /// `openapi.json`): on a response that key holds the server's SNAPSHOT, and
    /// `Draft.init` restates the selection from it.
    init(_ generated: Components.Schemas.DraftFields) {
        self.init(
            mailboxID: generated.mailboxId,
            replyToMessageID: generated.replyToMessageId,
            forwardOfMessageID: generated.forwardOfMessageId,
            from: generated.from,
            to: generated.to,
            cc: generated.cc,
            bcc: generated.bcc,
            subject: generated.subject,
            text: generated.text,
            html: generated.html,
            signature: nil,
            version: generated.version
        )
    }

    var generated: Components.Schemas.DraftInput {
        .init(
            mailboxId: mailboxID,
            replyToMessageId: replyToMessageID,
            forwardOfMessageId: forwardOfMessageID,
            from: from,
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            text: text,
            html: html,
            version: version,
            signature: signature?.generated
        )
    }
}

nonisolated extension Draft {
    init(_ generated: Components.Schemas.Draft) {
        self.init(
            id: generated.value2.id,
            version: generated.value2.version,
            updatedAt: generated.value2.updatedAt,
            attachments: generated.value2.attachments.map(DraftAttachment.init),
            signature: SignatureSnapshot(generated.value2.signature),
            content: DraftInput(generated.value1)
        )
    }
}

// MARK: - DTO → generated

nonisolated extension SendInput {
    var generated: Components.Schemas.SendInput {
        .init(
            from: from,
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            text: text,
            html: html,
            attachmentIds: attachmentIDs,
            draftId: draftID,
            signature: signature?.generated
        )
    }
}

nonisolated extension ForwardInput {
    var generated: Components.Schemas.ForwardInput {
        .init(
            messageId: messageID,
            from: from,
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            text: text,
            html: html,
            attachmentIds: attachmentIDs,
            includeOriginalAttachments: includeOriginalAttachments,
            signature: signature?.generated
        )
    }
}

nonisolated extension ReplyInput {
    var generated: Components.Schemas.ReplyInput {
        .init(
            messageId: messageID,
            from: from,
            to: to,
            cc: cc,
            bcc: bcc,
            text: text,
            html: html,
            attachmentIds: attachmentIDs,
            draftId: draftID,
            signature: signature?.generated
        )
    }
}

// MARK: - Errors

nonisolated extension MailAPIError {
    /// Normalises anything thrown out of the generated client.
    ///
    /// `AuthenticatingMiddleware` already turns non-2xx responses into
    /// `MailAPIError`; the runtime wraps that in `ClientError`, so unwrap first.
    static func mapping(_ error: any Error) -> MailAPIError {
        if let mailError = error as? MailAPIError { return mailError }
        if let clientError = error as? ClientError { return mapping(clientError.underlyingError) }
        // Issue #1: the token provider's failures were flattened into `.transport`,
        // so "no refresh token" / "refresh refused" surfaced as a generic sync error
        // with a Retry that could never succeed. A request that cannot be
        // authenticated IS `.unauthorized` — the one case every consumer already
        // routes to the re-authenticate banner and that stops the sync loop.
        if let oauth = error as? OAuthError {
            switch oauth {
            case .reauthenticationRequired, .missingRefreshToken: return .unauthorized
            default: return .transport(.init(oauth))
            }
        }
        if error is DecodingError { return .decoding }
        if let urlError = error as? URLError { return .transport(.init(urlError)) }
        // Body/schema failures surface as OpenAPIRuntime runtime errors, not DecodingError.
        if String(describing: type(of: error)).contains("RuntimeError") { return .decoding }
        return .transport(.init(error))
    }
}

// MARK: - MIME sniffing

/// The inline-image route responds with `image/*`; the generated client does not
/// surface the concrete `Content-Type`, so recover it from the bytes.
public nonisolated enum MIMESniffer {
    public static func imageType(of data: Data) -> String {
        let prefix = [UInt8](data.prefix(12))
        func starts(_ bytes: [UInt8]) -> Bool { prefix.count >= bytes.count && Array(prefix.prefix(bytes.count)) == bytes }

        if starts([0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts([0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if starts([0x52, 0x49, 0x46, 0x46]), prefix.count >= 12, Array(prefix[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        if starts([0x3C, 0x73, 0x76, 0x67]) || starts([0x3C, 0x3F, 0x78, 0x6D, 0x6C]) { return "image/svg+xml" }
        return Self.unknownType
    }

    /// The type we report when nothing is known — never a claim about the bytes.
    public static let unknownType = "application/octet-stream"

    /// Types that are real formats but also the envelope of many others (a .docx
    /// IS a zip). When the server declares something more specific, its word wins.
    private static let containerTypes: Set<String> = ["application/zip", "application/gzip", "image/svg+xml"]

    /// Best-effort type of an arbitrary downloaded part, from its magic bytes.
    /// `nil` when the bytes say nothing.
    public static func sniff(_ data: Data) -> String? {
        let prefix = [UInt8](data.prefix(12))
        func starts(_ bytes: [UInt8]) -> Bool { prefix.count >= bytes.count && Array(prefix.prefix(bytes.count)) == bytes }

        if starts([0x25, 0x50, 0x44, 0x46]) { return "application/pdf" }            // %PDF
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) || starts([0x50, 0x4B, 0x07, 0x08]) {
            return "application/zip"                                                // PK.. — also every OOXML/iWork file
        }
        if starts([0x7B, 0x5C, 0x72, 0x74, 0x66]) { return "application/rtf" }      // {\rtf
        if starts([0x1F, 0x8B]) { return "application/gzip" }
        if starts([0xD0, 0xCF, 0x11, 0xE0]) { return "application/x-ole-storage" }  // legacy .doc/.xls
        if starts([0x25, 0x21, 0x50, 0x53]) { return "application/postscript" }     // %!PS
        let image = imageType(of: data)
        // `imageType` answers SVG for ANY `<?xml` prolog because the inline-image
        // route only ever serves images. Here the part can be any XML at all, and
        // naming a `.xml` attachment `.svg` is exactly the mislabelling this
        // resolution exists to stop.
        if image == "image/svg+xml", !starts([0x3C, 0x73, 0x76, 0x67]) { return nil }
        return image == unknownType ? nil : image
    }

    /// The type to stage a downloaded attachment as.
    ///
    /// The server's `Attachment.contentType` is trustworthy metadata and is
    /// preferred; the bytes are the cross-check. `GET /attachments/{id}` gives the
    /// client no usable `Content-Type`, so before this the staged file was always
    /// `application/octet-stream` and Quick Look had nothing to work with.
    public static func resolve(declaredType: String?, data: Data) -> String {
        let declared = normalize(declaredType)
        let sniffed = sniff(data)
        guard let declared else { return sniffed ?? unknownType }
        guard let sniffed, sniffed != declared else { return declared }
        // A declared type that merely refines what the bytes can tell us (docx
        // inside a zip, svg inside xml) is the better answer.
        if containerTypes.contains(sniffed) { return declared }
        // Otherwise the bytes are ground truth: a mislabelled part must still open.
        return sniffed
    }

    /// Strips parameters and folds the "we don't know" spellings to `nil`.
    public static func normalize(_ type: String?) -> String? {
        guard let type else { return nil }
        let base = type.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces).lowercased()
        guard !base.isEmpty, base != unknownType, base != "binary/octet-stream", base != "application/unknown" else {
            return nil
        }
        return base
    }
}
