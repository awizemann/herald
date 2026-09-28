import Foundation
import HeraldKit
import Testing
@testable import Herald
import struct HeraldKit.Attachment

private func attachment(_ id: String, _ filename: String) -> Attachment {
    Attachment(
        id: id, messageID: "m1", filename: filename, contentType: "application/pdf",
        sizeBytes: 4, contentID: nil, disposition: .attachment, createdAt: MailFixtures.epoch
    )
}

private func scratchFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("attachment-card-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct FetchFailed: Error {}

@Suite("Download All")
@MainActor
struct DownloadAllTests {
    /// Fails if names are not de-duplicated Finder-style, or if a stem's own
    /// dots are mistaken for the extension.
    @Test func uniqueNamesFollowFinder() {
        let taken: Set<String> = ["report.pdf", "report 2.pdf", "notes", "a.b.tar"]
        #expect(AttachmentBatchSaver.uniqueName(for: "fresh.pdf") { taken.contains($0) } == "fresh.pdf")
        #expect(AttachmentBatchSaver.uniqueName(for: "report.pdf") { taken.contains($0) } == "report 3.pdf")
        #expect(AttachmentBatchSaver.uniqueName(for: "notes") { taken.contains($0) } == "notes 2")
        #expect(AttachmentBatchSaver.uniqueName(for: "a.b.tar") { taken.contains($0) } == "a.b 2.tar")
    }

    /// Two attachments with the same name, plus a file already in the folder:
    /// fails if any write replaces another (the user's file must survive).
    @Test func sameNamedAttachmentsNeverOverwrite() async throws {
        let folder = try scratchFolder()
        let sources = try scratchFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: sources)
        }
        try Data("existing".utf8).write(to: folder.appendingPathComponent("invoice.pdf"))
        let first = sources.appendingPathComponent("1/invoice.pdf")
        let second = sources.appendingPathComponent("2/invoice.pdf")
        for (url, body) in [(first, "one"), (second, "two")] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url)
        }
        let files = ["a": first, "b": second]

        let report = await AttachmentBatchSaver.save(
            [attachment("a", "invoice.pdf"), attachment("b", "invoice.pdf")],
            into: folder,
            fetch: { try #require(files[$0.id]) }
        )

        #expect(report.failed.isEmpty)
        #expect(report.saved.map(\.lastPathComponent) == ["invoice 2.pdf", "invoice 3.pdf"])
        func read(_ name: String) throws -> String {
            try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
        }
        #expect(try read("invoice.pdf") == "existing")
        #expect(try read("invoice 2.pdf") == "one")
        #expect(try read("invoice 3.pdf") == "two")
        // No staging leftovers in the user's folder.
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.filter { $0.hasPrefix(".") }.isEmpty)
    }

    /// Fails if one failed fetch aborts the batch or goes unreported, or if the
    /// pins taken for the files that DID download are never released.
    @Test func aPartialFailureSavesTheRestAndNamesTheMissing() async throws {
        let folder = try scratchFolder()
        let source = try scratchFolder().appendingPathComponent("ok.txt")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
        }
        try Data("ok".utf8).write(to: source)
        var released: [String] = []
        var progress: [Int] = []

        let report = await AttachmentBatchSaver.save(
            [attachment("a", "ok.txt"), attachment("b", "broken.pdf"), attachment("c", "ok.txt")],
            into: folder,
            fetch: { if $0.id == "b" { throw FetchFailed() }; return source },
            release: { released.append($0.id) },
            progress: { finished, _ in progress.append(finished) }
        )

        #expect(report.saved.map(\.lastPathComponent) == ["ok.txt", "ok 2.txt"])
        #expect(report.failed == ["broken.pdf"])
        #expect(report.failureMessage == "Herald could not download 1 of 3 attachments: broken.pdf.")
        #expect(released == ["a", "c"])
        #expect(progress == [0, 1, 2, 3], "0 of N is reported before the first fetch")
    }

    /// A copy that throws partway (disk full) after writing some bytes: fails
    /// if the hidden staging file is left behind in the user's folder, for
    /// the batch copy and the single-file install alike.
    @Test func aFailingCopyLeavesNoStagingFile() throws {
        let folder = try scratchFolder()
        let sources = try scratchFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: sources)
        }
        let source = sources.appendingPathComponent("big.pdf")
        try Data("payload".utf8).write(to: source)
        let partialCopy: (URL, URL) throws -> Void = { _, staging in
            try Data("pay".utf8).write(to: staging)
            throw FetchFailed()
        }

        #expect(throws: FetchFailed.self) {
            try AttachmentBatchSaver.copy(source, into: folder, copyFile: partialCopy)
        }
        #expect(throws: FetchFailed.self) {
            try AttachmentSaver.install(source, at: folder.appendingPathComponent("big.pdf"), copyFile: partialCopy)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func aTotalFailureSaysSoAndSuccessSaysNothing() {
        #expect(AttachmentBatchSaver.Report(saved: [], failed: ["x.pdf"]).failureMessage
            == "Herald could not download the attachments: x.pdf.")
        #expect(AttachmentBatchSaver.Report(saved: [URL(fileURLWithPath: "/tmp/x")], failed: []).failureMessage == nil)
    }

    @Test func headerCountIsSingularForOne() {
        #expect(ReadingPaneAttachments.summary(count: 1) == "1 attachment")
        #expect(ReadingPaneAttachments.summary(count: 3) == "3 attachments")
    }
}

@Suite("Attachment file-type symbol")
struct AttachmentFileTypeSymbolTests {
    @Test(arguments: [
        ("scan.PDF", "application/octet-stream", "doc.richtext"),
        ("photo.jpeg", "application/octet-stream", "photo"),
        ("archive.zip", "application/zip", "doc.zipper"),
        ("budget.xlsx", "application/octet-stream", "tablecells"),
        ("invite.ics", "text/calendar", "calendar"),
        // No extension: the content type decides.
        ("image", "image/png", "photo"),
        ("clip", "video/quicktime", "film"),
        ("README", "text/plain", "doc.plaintext"),
        // Extension beats a contradicting content type.
        ("deck.pptx", "application/pdf", "rectangle.on.rectangle"),
        ("mystery.bin", "application/octet-stream", "doc"),
        ("mystery", nil, "doc"),
    ] as [(String, String?, String)])
    func symbol(filename: String, contentType: String?, expected: String) {
        #expect(MailTheme.Symbol.fileType(filename: filename, contentType: contentType) == expected)
    }
}

@Suite("Compose local attachment copies")
struct ComposeLocalAttachmentsTests {
    private static func draft(_ ids: String...) -> [DraftAttachment] {
        ids.map { DraftAttachment(id: $0, filename: "\($0).txt", contentType: "text/plain", sizeBytes: 1) }
    }

    private let copy = URL(fileURLWithPath: "/tmp/copy-a")

    @Test func theNewAttachmentGetsTheCopy() {
        var local = ComposeLocalAttachments()
        let unrecorded = local.record(copy, before: Self.draft("x"), after: Self.draft("x", "a"))
        #expect(unrecorded == nil)
        #expect(local.url(for: "a", in: Self.draft("x", "a")) == copy)
        // A reopened draft's attachment (never uploaded this session) has none.
        #expect(local.url(for: "x", in: Self.draft("x", "a")) == nil)
    }

    /// Fails if an ambiguous upload result (no new id, or two) pins the copy to
    /// a guessed card — Quick Look would then show the wrong file.
    @Test func anAmbiguousUploadRecordsNothing() {
        var local = ComposeLocalAttachments()
        #expect(local.record(copy, before: Self.draft("x"), after: Self.draft("x")) == copy)
        #expect(local.record(copy, before: [], after: Self.draft("a", "b")) == copy)
        #expect(local.files.isEmpty)
    }

    /// Fails if a removed attachment keeps offering its copy, or its file leaks.
    @Test func removedAttachmentsLoseTheirCopy() {
        var local = ComposeLocalAttachments()
        _ = local.record(copy, before: [], after: Self.draft("a"))
        #expect(local.url(for: "a", in: []) == nil)
        #expect(local.prune(keeping: []) == [copy])
        #expect(local.files.isEmpty)
    }

    @Test func removeAllHandsBackEveryFile() {
        var local = ComposeLocalAttachments()
        _ = local.record(copy, before: [], after: Self.draft("a"))
        #expect(local.removeAll() == [copy])
        #expect(local.url(for: "a", in: Self.draft("a")) == nil)
    }
}

/// End to end through the composer: an upload leaves a local copy the card can
/// preview, and closing the window deletes it.
@MainActor
@Suite struct ComposeLocalCopyTests {
    @Test func anUploadedFileIsPreviewableUntilTheWindowCloses() async throws {
        let outbox = GatedOutbox()
        await outbox.setResult { draft in
            ComposeDraft(
                id: draft.id,
                mode: draft.mode,
                uploadedAttachments: [
                    DraftAttachment(id: "att_1", filename: "notes.txt", contentType: "text/plain", sizeBytes: 5),
                ]
            )
        }
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: outbox
        )
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let own = folder.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: own)

        await model.attach(own)

        let attachment = try #require(model.attachments.first)
        let local = try #require(model.localFile(for: attachment))
        #expect(local != own)
        #expect(AttachmentScratchpad.contains(local))
        #expect(try String(contentsOf: local, encoding: .utf8) == "hello")

        model.releaseLocalFiles()
        #expect(model.localFile(for: attachment) == nil)
        #expect(FileManager.default.fileExists(atPath: local.path) == false)
        // The user's own file is never touched.
        #expect(FileManager.default.fileExists(atPath: own.path))
    }
}
