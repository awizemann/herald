import Foundation
import HeraldKit
import Testing
@testable import Herald
// `Testing` exports an `Attachment` of its own; this names ours for the file.
import struct HeraldKit.Attachment

private func part(
    id: String = "att_1",
    filename: String,
    contentType: String,
    contentID: String? = nil,
    disposition: AttachmentDisposition = .attachment
) -> Attachment {
    Attachment(
        id: id,
        messageID: "m1",
        filename: filename,
        contentType: contentType,
        sizeBytes: 4,
        contentID: contentID,
        disposition: disposition,
        createdAt: MailFixtures.epoch
    )
}

@Suite("Attachment staging")
struct AttachmentStagingTests {
    /// Fails if the resolved content type is ignored: an extension-less name is
    /// what left Quick Look with nothing to pick a previewer from.
    @Test func missingExtensionIsAddedFromTheContentType() {
        let name = AttachmentFile.filename(for: part(filename: "invoice", contentType: "application/pdf"), contentType: nil)
        #expect(name == "invoice.pdf")
    }

    /// Fails if a WRONG extension is left alone: the server's `.dat` (or a
    /// `.txt` on a PDF) beats Quick Look just as thoroughly as no extension.
    @Test func contradictoryExtensionIsCorrected() {
        let name = AttachmentFile.filename(
            for: part(filename: "invoice.dat", contentType: "application/octet-stream"),
            contentType: "application/pdf"
        )
        #expect(name == "invoice.dat.pdf", "The user's filename is kept; the real extension is appended")
    }

    /// Fails if the correction fires on a name that is already right — renaming
    /// `logo.png` to `logo.png.png` would be a regression of its own.
    @Test func correctExtensionIsLeftAlone() {
        #expect(AttachmentFile.filename(for: part(filename: "logo.png", contentType: "image/png"), contentType: nil)
            == "logo.png")
        // `.jpg` conforms to `public.jpeg`; a resolved `image/jpeg` must accept it.
        #expect(AttachmentFile.filename(for: part(filename: "photo.jpg", contentType: "image/jpeg"), contentType: nil)
            == "photo.jpg")
    }

    /// Fails if an unknown type invents an extension out of nothing.
    @Test func unknownTypeLeavesTheNameAlone() {
        #expect(AttachmentFile.filename(
            for: part(filename: "mystery", contentType: "application/octet-stream"),
            contentType: nil
        ) == "mystery")
    }

    /// APFS's 255-byte filename limit is on UTF-8 bytes, not `Character`s. A
    /// multi-byte name (each "é" here is 2 bytes) clamped by character count
    /// alone can still exceed 255 bytes and fail the write. Fails if the
    /// resulting name is over budget, or if truncation lands mid-scalar and
    /// produces something that is not even valid UTF-8 when re-decoded.
    @Test func multiByteFilenameIsClampedByUTF8BytesNotCharacters() {
        let longMultiByte = String(repeating: "é", count: 300)
        let name = AttachmentFile.filename(
            for: part(filename: longMultiByte, contentType: "application/octet-stream"),
            contentType: nil
        )
        #expect(name.utf8.count <= 255)
        #expect(String(decoding: Array(name.utf8), as: UTF8.self) == name, "truncation must land on a scalar boundary")
    }

    /// The same clamp applies when an extension has to be appended: the
    /// extension must still fit inside the 255-byte budget after a multi-byte
    /// base name is truncated for it.
    @Test func multiByteFilenameWithAppendedExtensionStaysWithinByteBudget() {
        let longMultiByte = String(repeating: "日", count: 200) // 3 bytes each in UTF-8
        let name = AttachmentFile.filename(
            for: part(filename: longMultiByte, contentType: "application/octet-stream"),
            contentType: "application/pdf"
        )
        #expect(name.utf8.count <= 255)
        #expect(name.hasSuffix(".pdf"))
    }

    /// A plain-ASCII name well under the limit must be left untouched — the
    /// byte clamp must not be an off-by-one that trims names that already fit.
    @Test func shortAsciiFilenameIsUnaffectedByTheByteClamp() {
        #expect(AttachmentFile.clampedToUTF8Bytes("invoice.pdf", limit: 255) == "invoice.pdf")
    }
}

@Suite("Attachment cache eviction")
struct AttachmentEvictionTests {
    /// Fails if eviction is a blind "drop the oldest": the file under a live
    /// Quick Look panel (or a drag Finder is still copying) would be deleted.
    @Test func aPinnedFileSurvivesEvictionAndGoesWhenUnpinned() async throws {
        let api = FakeMailAPIClient()
        let cache = AttachmentFile(cacheLimit: 2)
        let first = part(id: "a1", filename: "a1.txt", contentType: "text/plain")

        let pinnedURL = try await cache.url(for: first, using: api)
        await cache.pin(first.id)

        for index in 2...4 {
            _ = try await cache.url(
                for: part(id: "a\(index)", filename: "a\(index).txt", contentType: "text/plain"),
                using: api
            )
        }

        #expect(
            FileManager.default.fileExists(atPath: pinnedURL.path),
            "The pinned file must outlive the eviction limit"
        )

        // Unpinned, it is once again the oldest entry and the next download over
        // the limit takes it.
        await cache.unpin(first.id)
        _ = try await cache.url(for: part(id: "a5", filename: "a5.txt", contentType: "text/plain"), using: api)
        #expect(!FileManager.default.fileExists(atPath: pinnedURL.path), "An unpinned file is evictable again")
    }

    /// Fails if eviction stops at the first pinned entry instead of skipping it:
    /// the cache would then never shed anything while a panel is open.
    @Test func unpinnedFilesStillEvictAroundAPin() async throws {
        let api = FakeMailAPIClient()
        let cache = AttachmentFile(cacheLimit: 2)
        let pinned = part(id: "a1", filename: "a1.txt", contentType: "text/plain")
        let pinnedURL = try await cache.url(for: pinned, using: api)
        await cache.pin(pinned.id)

        let second = part(id: "a2", filename: "a2.txt", contentType: "text/plain")
        let secondURL = try await cache.url(for: second, using: api)
        for index in 3...5 {
            _ = try await cache.url(
                for: part(id: "a\(index)", filename: "a\(index).txt", contentType: "text/plain"),
                using: api
            )
        }

        #expect(FileManager.default.fileExists(atPath: pinnedURL.path))
        #expect(!FileManager.default.fileExists(atPath: secondURL.path), "Unpinned entries must still be evicted")
        await cache.unpin(pinned.id)
    }
}

@Suite("Inline image substitution")
struct InlineSubstitutionTests {
    private let images = ["logo@cid": "data:image/png;base64,AAAA"]

    /// Fails if substitution is a global string replace: it also rewrote `cid:`
    /// text the sender wrote in the body, silently corrupting the message.
    @Test func onlySourceAttributesAreRewritten() {
        let html = """
        <p>Reference cid:logo@cid in prose</p>\
        <img src="cid:logo@cid"><img src='cid:<logo@cid>'><td background="cid:logo@cid">\
        <a href="cid:logo@cid" title="see src=cid:logo@cid here">link</a>
        """
        let expected = """
        <p>Reference cid:logo@cid in prose</p>\
        <img src="data:image/png;base64,AAAA"><img src='data:image/png;base64,AAAA'>\
        <td background="data:image/png;base64,AAAA">\
        <a href="cid:logo@cid" title="see src=cid:logo@cid here">link</a>
        """
        // Whole-document equality, not `contains`: the point of the change is
        // that NOTHING else moved — prose, `href`, and a `src=cid:` written
        // inside another attribute's value all stay exactly as the sender wrote
        // them.
        #expect(MailViewModel.substituteInlineImages(in: html, with: images) == expected)
    }

    /// Fails if the attribute name is matched case-sensitively: `<IMG SRC=…>` is
    /// ordinary mail, and leaving it alone is a broken image plus a spurious
    /// "could not be loaded" note.
    @Test func uppercaseAttributesAreRewritten() {
        let output = MailViewModel.substituteInlineImages(in: "<IMG SRC=\"cid:logo@cid\">", with: images)
        #expect(output == "<IMG SRC=\"data:image/png;base64,AAAA\">")
    }

    /// Fails if a content ID we could not fetch is rewritten to something bogus.
    @Test func unknownContentIDsAreLeftIntact() {
        let html = "<img src=\"cid:missing@cid\">"
        #expect(MailViewModel.substituteInlineImages(in: html, with: images) == html)
    }
}

@MainActor
@Suite("Offline attachment bar")
struct OfflineAttachmentTests {
    /// Fails if the detail route is the only source of attachments: offline, the
    /// whole attachment bar vanished while the body still rendered from cache.
    @Test func aFailedDetailFetchFallsBackToTheCachedAttachments() async throws {
        let store = try MailStore.inMemory()
        let api = FakeMailAPIClient()
        let (stream, _) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .unbounded)
        let model = MailViewModel(
            accountID: "acct",
            accountLabel: "Test",
            api: api,
            store: store,
            actions: MailActionService(api: api, store: store),
            events: stream,
            markReadDelay: .seconds(3600)
        )

        let message = MailFixtures.message(id: "m1", threadID: "t1", mailboxID: "mbA", hasAttachments: true)
        try await store.upsertMessages([message], accountID: "acct")
        try await store.upsertConversations(
            [MailFixtures.conversation(message)], accountID: "acct", mailboxID: "mbA", folder: .inbox
        )
        let attachments = [
            part(filename: "invoice.pdf", contentType: "application/pdf"),
            part(id: "att_2", filename: "logo.png", contentType: "image/png", contentID: "logo@cid", disposition: .inline),
        ]
        try await store.storeBody(
            messageID: "m1",
            accountID: "acct",
            textBody: "cached text",
            html: nil,
            attachments: attachments
        )

        // No detail was seeded on the fake, so `GET /messages/{id}` fails —
        // exactly the offline case.
        model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await model.start()
        model.selectedThreadID = "t1"

        try await wait("the cached detail to stand in for the failed fetch") {
            model.detail?.downloadableAttachments.map(\.id) == ["att_1"]
        }
        #expect(model.detail?.attachments.count == 2, "The inline part is cached too, for the cid: substitution")
        #expect(model.actionError == nil, "A usable cached fallback must not raise an error banner")
    }

    /// Fails if the fallback swallows a DECODING failure: a server whose
    /// `MessageDetail` no longer decodes (an instance older than the required
    /// `disposition` field) would then serve stale cached detail forever with no
    /// sign that the detail route is broken.
    @Test func aDecodingFailureIsReportedRatherThanPapredOver() async throws {
        let store = try MailStore.inMemory()
        let api = FakeMailAPIClient()
        let (stream, _) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .unbounded)
        let model = MailViewModel(
            accountID: "acct",
            accountLabel: "Test",
            api: api,
            store: store,
            actions: MailActionService(api: api, store: store),
            events: stream,
            markReadDelay: .seconds(3600)
        )

        let message = MailFixtures.message(id: "m1", threadID: "t1", mailboxID: "mbA", hasAttachments: true)
        try await store.upsertMessages([message], accountID: "acct")
        try await store.upsertConversations(
            [MailFixtures.conversation(message)], accountID: "acct", mailboxID: "mbA", folder: .inbox
        )
        try await store.storeBody(
            messageID: "m1",
            accountID: "acct",
            textBody: "cached text",
            html: nil,
            attachments: [part(filename: "invoice.pdf", contentType: "application/pdf")]
        )
        await api.setDetailError(.decoding)

        model.selection = .init(mailboxID: "mbA", folder: .inbox)
        await model.start()
        model.selectedThreadID = "t1"

        try await wait("the decoding failure to surface") { model.actionError != nil }
        #expect(model.detail == nil, "A broken contract must not be masked by cached detail")
    }
}
