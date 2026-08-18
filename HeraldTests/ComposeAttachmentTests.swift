import Foundation
import HeraldKit
import Testing
@testable import Herald

/// An outbox whose `attach` can be held open, so "while the upload is in flight"
/// is an assertable state instead of a hope.
actor GatedOutbox: Outboxing {
    private(set) var attached: [URL] = []
    /// Whether each attached file still existed when the upload started — the
    /// only way to prove a staged temp file is deleted AFTER the upload, not before.
    private(set) var existedAtAttach: [Bool] = []
    private(set) var sendCount = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var isGated = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Stands in for a server that really stored the upload.
    private var result: (@Sendable (ComposeDraft) -> ComposeDraft)?

    func arm() { isGated = true }

    func setResult(_ result: @escaping @Sendable (ComposeDraft) -> ComposeDraft) { self.result = result }

    func open() {
        isGated = false
        gate?.resume()
        gate = nil
    }

    /// Suspends until `attach` has actually been entered.
    func waitForAttach() async {
        guard attached.isEmpty else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func attach(_ fileURL: URL, to draft: ComposeDraft) async throws(OutboxError) -> ComposeDraft {
        attached.append(fileURL)
        existedAtAttach.append(FileManager.default.fileExists(atPath: fileURL.path))
        for waiter in waiters { waiter.resume() }
        waiters = []
        if isGated {
            await withCheckedContinuation { gate = $0 }
        }
        return result?(draft) ?? draft
    }

    @discardableResult
    func saveDraft(_ draft: ComposeDraft) async throws(OutboxError) -> ComposeDraft { draft }
    func discard(_ draft: ComposeDraft) async throws(OutboxError) {}
    func removeAttachment(_ id: String, from draft: ComposeDraft) async throws(OutboxError) -> ComposeDraft { draft }
    @discardableResult
    func send(_ draft: ComposeDraft) async throws(OutboxError) -> MessageSummary {
        sendCount += 1
        return MailFixtures.message(id: "sent")
    }
}

@MainActor
@Suite struct ComposeAttachmentTests {
    private static func model(_ outbox: any Outboxing) -> ComposeViewModel {
        ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: outbox
        )
    }

    private static func file(named name: String, bytes: Int = 8) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("compose-attachment-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    /// Fails on the pre-P2 behaviour, where an upload was invisible until it
    /// landed: on a slow link the user saw nothing happen and picked the file again.
    @Test func anUploadInFlightIsVisibleAndDisappearsWhenItLands() async throws {
        let outbox = GatedOutbox()
        await outbox.arm()
        let model = Self.model(outbox)
        let url = try Self.file(named: "report.pdf", bytes: 16)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let attaching = Task { await model.attach(url) }
        await outbox.waitForAttach()
        #expect(model.pendingUploads.map(\.filename) == ["report.pdf"])
        #expect(model.pendingUploads.first?.byteCount == 16)

        await outbox.open()
        await attaching.value
        #expect(model.pendingUploads.isEmpty)
    }

    /// Fails if cancelling leaves the chip behind (the window would look busy
    /// forever) or leaves the composer stuck in `.saving`.
    @Test func cancellingAnUploadClearsTheChipAndTheBusyState() async throws {
        let outbox = GatedOutbox()
        await outbox.arm()
        let model = Self.model(outbox)
        let url = try Self.file(named: "big.bin")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let attaching = Task { await model.attach(url) }
        await outbox.waitForAttach()
        let pending = try #require(model.pendingUploads.first)
        model.cancelUpload(pending.id)

        #expect(model.pendingUploads.isEmpty)
        #expect(model.isBusy == false)
        await outbox.open()
        await attaching.value
    }

    /// The per-draft byte total is only correct if uploads are serialized: two
    /// concurrent ones each measure the total against the same pre-upload draft,
    /// so a pair that fits only individually would both pass and the server would
    /// 413 the second. Fails on any implementation that starts them in parallel.
    @Test func concurrentAttachesReachTheOutboxOneAtATime() async throws {
        let outbox = GatedOutbox()
        await outbox.arm()
        let model = Self.model(outbox)
        let first = try Self.file(named: "a.bin")
        let second = try Self.file(named: "b.bin")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }

        let running = Task { await model.attach([first, second]) }
        await outbox.waitForAttach()
        for _ in 0..<10 { await Task.yield() }
        #expect(await outbox.attached == [first])
        // Both chips are up, though only one upload is running.
        #expect(model.pendingUploads.count == 2)

        await outbox.open()
        await running.value
        #expect(await outbox.attached == [first, second])
    }

    /// The composer binds ⌘V, which takes it away from the responder chain. Fails
    /// if a text-only paste is reported as consumed — the body could then never be
    /// pasted into again.
    @Test func aTextOnlyPasteIsNotConsumed() async {
        let model = Self.model(GatedOutbox())
        let consumed = await model.paste(PasteboardContents(hasText: true))
        #expect(consumed == false)
        #expect(model.pendingUploads.isEmpty)
    }

    /// Two halves of the same rule: bytes pasted from the clipboard are staged in
    /// Herald's scratch directory and cleaned up after the upload, and a file the
    /// USER picked is never deleted. Fails on a cleanup that deletes by URL
    /// without asking whose file it is.
    @Test func aPastedImageIsStagedThenCleanedUpButTheUsersOwnFileIsNot() async throws {
        let outbox = GatedOutbox()
        let model = Self.model(outbox)

        let consumed = await model.paste(
            PasteboardContents(images: [PasteboardImage(data: Data([0x89, 0x50]), filenameExtension: "png")])
        )
        #expect(consumed)
        let staged = try #require(await outbox.attached.first)
        #expect(AttachmentScratchpad.contains(staged))
        #expect(await outbox.existedAtAttach == [true])
        #expect(FileManager.default.fileExists(atPath: staged.path) == false)

        let own = try Self.file(named: "notes.txt")
        defer { try? FileManager.default.removeItem(at: own.deletingLastPathComponent()) }
        await model.attach(own)
        #expect(FileManager.default.fileExists(atPath: own.path))
    }

    /// Cancel does not reach the server — the upload it was already waiting on can
    /// still succeed. Fails if that result is thrown away: the local attachment
    /// list would then be missing a file the DRAFT has, every later per-draft
    /// total would be measured short, and the next upload would 413.
    @Test func aCancelledUploadThatLandedAnywayStillCountsAgainstTheDraft() async throws {
        let outbox = GatedOutbox()
        await outbox.arm()
        await outbox.setResult { draft in
            ComposeDraft(
                id: draft.id,
                mode: draft.mode,
                uploadedAttachments: [
                    DraftAttachment(id: "att_1", filename: "big.bin", contentType: "text/plain", sizeBytes: 8),
                ]
            )
        }
        let model = Self.model(outbox)
        let url = try Self.file(named: "big.bin")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let attaching = Task { await model.attach(url) }
        await outbox.waitForAttach()
        let pending = try #require(model.pendingUploads.first)
        model.cancelUpload(pending.id)
        await outbox.open()
        await attaching.value

        #expect(model.attachments.map(\.id) == ["att_1"])
    }

    /// Fails if ⌘⇧D can beat a queued upload: the message would go out without the
    /// file the user just dropped on it, and the upload would land on a draft that
    /// no longer exists.
    @Test func sendWaitsForQueuedUploads() async throws {
        let outbox = GatedOutbox()
        await outbox.arm()
        let model = Self.model(outbox)
        model.toText = "ada@example.net"
        let url = try Self.file(named: "late.bin")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let attaching = Task { await model.attach(url) }
        await outbox.waitForAttach()
        let sending = Task { await model.send() }
        for _ in 0..<10 { await Task.yield() }
        #expect(await outbox.sendCount == 0)

        await outbox.open()
        await attaching.value
        #expect(await sending.value)
        #expect(await outbox.sendCount == 1)
    }

    /// Fails if a dropped folder is uploaded as if it were a file — the outbox
    /// would read a directory and the user would get an unreadable-file error.
    @Test func droppingAFolderAttachesNothing() async throws {
        let outbox = GatedOutbox()
        let model = Self.model(outbox)
        let file = try Self.file(named: "inside.txt")
        let folder = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }

        await model.drop([folder, file])
        #expect(await outbox.attached == [file])
    }
}
