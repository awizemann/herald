import Foundation
import Testing
@testable import HeraldKit

/// Paste-to-attach has exactly one decision worth testing: what a given
/// pasteboard becomes. Everything else is AppKit.
@Suite struct AttachmentPasteboardTests {
    static let png = PasteboardImage(data: Data([0x89, 0x50]), filenameExtension: "png")

    /// Copying a file in Finder puts BOTH a file URL and the rendered image on the
    /// pasteboard. Fails on an implementation that reads images first — the user
    /// would get "Pasted Image ….tiff" instead of their own file, re-encoded.
    @Test("A pasteboard with both a file URL and an image attaches the file")
    func fileWinsOverImage() {
        let file = URL(fileURLWithPath: "/tmp/report.pdf")
        let result = AttachmentPasteboard.attachments(
            from: PasteboardContents(fileURLs: [file], images: [Self.png], hasText: true)
        )
        #expect(result == [.file(file)])
    }

    /// Fails if a plain-text paste is treated as an attachment paste: the compose
    /// window forwards ⌘V to the text view only on an EMPTY result, so a
    /// false positive here means the body can never be pasted into again.
    @Test("Text-only and empty pasteboards produce nothing to attach")
    func textPasteIsNotConsumed() {
        #expect(AttachmentPasteboard.attachments(from: PasteboardContents(hasText: true)).isEmpty)
        #expect(AttachmentPasteboard.attachments(from: PasteboardContents()).isEmpty)
    }

    /// Copying from Preview, Numbers or any rich-text source puts a SYNTHESIZED
    /// image on the pasteboard next to the text. Fails on a build that attaches
    /// it: pasting copied text into the body would produce a picture of the
    /// selection and no text at all.
    @Test("Text alongside an image is a text paste, not an attachment")
    func textAlongsideAnImageIsNotAnAttachment() {
        let contents = PasteboardContents(images: [Self.png], hasText: true)
        #expect(AttachmentPasteboard.attachments(from: contents).isEmpty)
        // …but a copied image on its own carries no text and IS an attachment.
        #expect(AttachmentPasteboard.attachments(from: PasteboardContents(images: [Self.png])).count == 1)
    }

    /// Fails if non-file URLs (a copied link) are attached — dragging a URL onto
    /// the composer must not upload a zero-byte file named after a hostname.
    @Test("A copied web URL is not an attachment")
    func remoteURLIsIgnored() {
        let contents = PasteboardContents(fileURLs: [URL(string: "https://example.com/x.pdf")!], hasText: true)
        #expect(AttachmentPasteboard.attachments(from: contents).isEmpty)
    }

    /// Fails if two images pasted at once get the same generated name: they would
    /// collide in the staging directory and the second would overwrite the first.
    @Test("Pasted images get timestamped, non-colliding names with the right extension")
    func imageNaming() throws {
        let jpeg = PasteboardImage(data: Data([0xFF, 0xD8]), filenameExtension: "jpeg")
        let at = try #require(
            DateComponents(
                calendar: .current,
                timeZone: .current,
                year: 2026, month: 8, day: 18, hour: 14, minute: 30, second: 5
            ).date
        )
        let result = AttachmentPasteboard.attachments(
            from: PasteboardContents(images: [Self.png, jpeg]),
            now: at
        )
        #expect(result == [
            .image(Self.png, filename: "Pasted Image 2026-08-18 at 14.30.05.png"),
            .image(jpeg, filename: "Pasted Image 2026-08-18 at 14.30.05 (2).jpeg"),
        ])
    }
}
