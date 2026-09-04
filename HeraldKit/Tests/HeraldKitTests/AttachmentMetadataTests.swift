import Foundation
import Testing
@testable import HeraldKit
// `Testing` also exports an `Attachment`; this names ours for the whole file.
import struct HeraldKit.Attachment

/// The attachment metadata rules: what type a downloaded part really is, what
/// "inline" means, and what survives in the cache when the detail route does not.
@Suite("Attachment metadata")
struct AttachmentMetadataTests {
    private static func attachment(
        id: String = "att_1",
        filename: String = "file",
        contentType: String = "application/pdf",
        contentID: String? = nil,
        disposition: AttachmentDisposition
    ) -> Attachment {
        Attachment(
            id: id,
            messageID: "msg_01",
            filename: filename,
            contentType: contentType,
            sizeBytes: 10,
            contentID: contentID,
            disposition: disposition,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - MIME resolution

    /// Fails if the sniffer only knows images: a PDF that the server labels
    /// `application/octet-stream` is exactly the case that produced `.dat` files
    /// Quick Look would not preview.
    @Test("Magic bytes identify the common attachment formats")
    func sniffsCommonFormats() {
        #expect(MIMESniffer.sniff(Data("%PDF-1.7\n…".utf8)) == "application/pdf")
        #expect(MIMESniffer.sniff(Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00])) == "application/zip")
        #expect(MIMESniffer.sniff(Data("{\\rtf1\\ansi".utf8)) == "application/rtf")
        #expect(MIMESniffer.sniff(Data([0x1F, 0x8B, 0x08, 0x00])) == "application/gzip")
        #expect(MIMESniffer.sniff(Data([0x89, 0x50, 0x4E, 0x47])) == "image/png")
        #expect(MIMESniffer.sniff(Data("just some prose".utf8)) == nil, "Unknown bytes must not be guessed at")
    }

    /// The server's metadata is trustworthy and wins; the bytes are the fallback.
    @Test("An octet-stream declaration falls through to the bytes")
    func resolvesUnknownDeclarationFromBytes() {
        #expect(MIMESniffer.resolve(declaredType: "application/octet-stream", data: Data("%PDF-1.4".utf8))
            == "application/pdf")
        #expect(MIMESniffer.resolve(declaredType: nil, data: Data("%PDF-1.4".utf8)) == "application/pdf")
        #expect(MIMESniffer.resolve(declaredType: "", data: Data("nothing".utf8)) == "application/octet-stream")
    }

    /// Fails if the sniff blindly overrides the server: a .docx IS a zip, and
    /// answering `application/zip` would open Archive Utility instead of Word.
    @Test("A declared type that refines the bytes is kept")
    func keepsRefiningDeclaration() {
        let docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        #expect(MIMESniffer.resolve(declaredType: docx, data: Data([0x50, 0x4B, 0x03, 0x04])) == docx)
        #expect(MIMESniffer.resolve(declaredType: "image/png; charset=binary", data: Data([0x89, 0x50, 0x4E, 0x47]))
            == "image/png")
    }

    /// Fails if the declaration is taken on faith: a part labelled `image/png`
    /// whose bytes are a PDF must be staged as a PDF or nothing previews it.
    @Test("Bytes overrule a declaration that contradicts them")
    func bytesWinOnContradiction() {
        #expect(MIMESniffer.resolve(declaredType: "image/png", data: Data("%PDF-1.6".utf8)) == "application/pdf")
    }

    // MARK: - Disposition

    /// The 1.3.4 rule, verbatim: "a content ID does not make a part inline".
    /// Fails if inline-ness is re-derived from `contentID`, which hid real
    /// attachments from the bar and tried to render PDFs as body images.
    @Test("Inline-ness comes from the server's disposition, not from contentID")
    func dispositionDecidesInline() {
        let pdfWithCID = Self.attachment(filename: "invoice.pdf", contentID: "part1@mail", disposition: .attachment)
        let imageWithoutCID = Self.attachment(id: "att_2", contentType: "image/png", disposition: .inline)

        #expect(!pdfWithCID.isInline)
        #expect(imageWithoutCID.isInline)

        let detail = MessageDetail(
            summary: SyncFixtures.message("msg_01"),
            cc: [],
            bcc: [],
            deliveredToAddress: nil,
            textBody: "",
            htmlAvailable: true,
            rfcMessageID: nil,
            inReplyTo: nil,
            references: [],
            attachments: [pdfWithCID, imageWithoutCID]
        )
        #expect(detail.downloadableAttachments.map { $0.id } == ["att_1"])
    }

    // MARK: - Offline cache

    /// Fails if attachment metadata is not persisted: offline, the whole
    /// attachment bar used to vanish while the body still rendered from cache.
    @Test("Attachment metadata survives in the body cache")
    func attachmentsAreCached() async throws {
        let store = try MailStore.inMemory()
        let account = SyncFixtures.account
        let attachments = [Self.attachment(filename: "invoice.pdf", disposition: .attachment)]

        _ = try await store.storeBody(
            messageID: "m1",
            accountID: account,
            textBody: "body",
            html: "<p>hi</p>",
            attachments: attachments
        )

        let cached = try #require(try await store.cachedBody(messageID: "m1", accountID: account))
        #expect(cached.attachments == attachments)
    }

    /// Fails if a later write with no attachment knowledge (the plain-text body
    /// path) wipes the metadata a detail fetch already cached.
    @Test("A body write that knows no attachments does not clear the cached ones")
    func emptyWriteKeepsAttachments() async throws {
        let store = try MailStore.inMemory()
        let account = SyncFixtures.account
        let attachments = [Self.attachment(disposition: .attachment)]
        _ = try await store.storeBody(
            messageID: "m1",
            accountID: account,
            textBody: "body",
            html: nil,
            attachments: attachments
        )

        _ = try await store.storeBody(messageID: "m1", accountID: account, textBody: "body 2", html: nil)

        let cached = try #require(try await store.cachedBody(messageID: "m1", accountID: account))
        #expect(cached.attachments == attachments)
        #expect(cached.textBody == "body 2")
    }
}
