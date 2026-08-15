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

nonisolated extension Attachment {
    init(_ generated: Components.Schemas.Attachment) {
        self.init(
            id: generated.id,
            messageID: generated.messageId,
            filename: generated.filename,
            contentType: generated.contentType,
            sizeBytes: generated.sizeBytes,
            contentID: generated.contentId,
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
            hasRemoteImages: generated.hasRemoteImages,
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

nonisolated extension DraftInput {
    init(_ generated: Components.Schemas.DraftInput) {
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
            version: version
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
            draftId: draftID
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
            draftId: draftID
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
nonisolated enum MIMESniffer {
    static func imageType(of data: Data) -> String {
        let prefix = [UInt8](data.prefix(12))
        func starts(_ bytes: [UInt8]) -> Bool { prefix.count >= bytes.count && Array(prefix.prefix(bytes.count)) == bytes }

        if starts([0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts([0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if starts([0x52, 0x49, 0x46, 0x46]), prefix.count >= 12, Array(prefix[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        if starts([0x3C, 0x73, 0x76, 0x67]) || starts([0x3C, 0x3F, 0x78, 0x6D, 0x6C]) { return "image/svg+xml" }
        return "application/octet-stream"
    }
}
