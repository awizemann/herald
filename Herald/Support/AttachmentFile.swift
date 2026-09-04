import AppKit
import Foundation
import HeraldKit
import OSLog
import UniformTypeIdentifiers

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "Attachments")

/// Downloads a received attachment once and keeps the staged file for the rest of
/// the launch, so Quick Look and a drag to Finder share one download.
///
/// An actor because two chips (or a Quick Look and a drag of the same chip) can
/// ask at the same time; `inFlight` makes the second caller join the first
/// download instead of racing it to the same path.
actor AttachmentFile {
    static let shared = AttachmentFile()

    /// How many downloaded attachments stay on disk before the oldest is dropped.
    /// Injectable so the eviction rules are testable without staging seventeen files.
    private let cacheLimit: Int

    init(cacheLimit: Int = 16) {
        self.cacheLimit = cacheLimit
    }

    private var staged: [String: URL] = [:]
    /// Attachment ids in least-recently-staged order; the eviction queue.
    private var order: [String] = []
    private var inFlight: [String: Task<URL, any Error>] = [:]
    /// Refcount per attachment id: a file with a live Quick Look panel, a drag in
    /// flight or a save copying it out must not be deleted under its user.
    private var pins: [String: Int] = [:]

    /// Holds the staged file in place while `body` runs.
    ///
    /// Eviction used to be able to delete the file a Quick Look panel was showing
    /// (the panel goes blank) or the file Finder was still copying out of a drag,
    /// simply because sixteen other attachments were opened after it.
    func pin(_ id: String) {
        pins[id, default: 0] += 1
    }

    func unpin(_ id: String) {
        guard let count = pins[id] else { return }
        if count <= 1 {
            pins[id] = nil
            // The entry may have survived only because it was pinned.
            evictIfNeeded()
        } else {
            pins[id] = count - 1
        }
    }

    /// The local file for an attachment, downloading it if this is the first ask.
    ///
    /// The file is quarantined: it came off the network, and the user may well
    /// drag it straight into Finder and double-click it.
    /// `pinned: true` takes the pin INSIDE the actor, in the same isolated step
    /// that hands the URL over: pinning from the caller after `url(for:)`
    /// returned left two actor hops in which a concurrent download's eviction
    /// could still delete the file being handed out.
    func url(for attachment: Attachment, using api: any MailAPIClient, pinned: Bool = false) async throws -> URL {
        if let existing = staged[attachment.id], FileManager.default.fileExists(atPath: existing.path) {
            if pinned { pin(attachment.id) }
            return existing
        }
        if let running = inFlight[attachment.id] {
            let url = try await running.value
            if pinned { pin(attachment.id) }
            return url
        }
        // The bookkeeping happens INSIDE the task, not around the `await`: a caller
        // that cancels (a Finder drag let go early) would otherwise clear `inFlight`
        // while this download keeps running, so the file it writes is never
        // recorded — leaked for the launch — and the next ask downloads it again.
        let task = Task<URL, any Error> { [api] in
            do {
                let payload = try await api.attachmentData(id: attachment.id)
                let filename = Self.filename(
                    for: attachment,
                    contentType: MIMESniffer.resolve(declaredType: attachment.contentType, data: payload.data)
                )
                // The download can be tens of MiB; staging it is blocking work.
                let url = try await Task.detached(priority: .userInitiated) { @Sendable [payload] in
                    let url = try AttachmentScratchpad.stage(payload.data, filename: filename)
                    AttachmentSaver.quarantine(url)
                    return url
                }.value
                await self.finish(attachment.id, with: url)
                return url
            } catch {
                await self.finish(attachment.id, with: nil)
                throw error
            }
        }
        inFlight[attachment.id] = task
        let url = try await task.value
        // Back inside the actor: the pin lands before any other caller can run,
        // so `finish`'s eviction cannot take this file between here and the
        // caller's first use of it.
        if pinned { pin(attachment.id) }
        return url
    }

    private func finish(_ id: String, with url: URL?) {
        if let url {
            staged[id] = url
            order.removeAll { $0 == id }
            order.append(id)
            evictIfNeeded()
        }
        inFlight[id] = nil
    }

    /// Herald is left open for weeks; without an eviction the previewed
    /// attachments of every message read in that time stay on disk at up to
    /// 25 MiB each. The cache is a convenience, not a store.
    ///
    /// Pinned entries are SKIPPED rather than deleted: the cache may overshoot
    /// its limit while a panel is open, and comes back down the moment the pin
    /// is dropped (`unpin` re-runs this).
    private func evictIfNeeded() {
        var index = 0
        while order.count > cacheLimit, index < order.count {
            let candidate = order[index]
            guard pins[candidate] == nil else {
                index += 1
                continue
            }
            order.remove(at: index)
            if let stale = staged.removeValue(forKey: candidate) { AttachmentScratchpad.discard(stale) }
        }
    }

    /// A filename Quick Look and Finder can act on.
    ///
    /// The server's `filename` is attacker-influenced and sometimes extension-less
    /// or plain wrong (`invoice.dat` for a PDF). Quick Look picks its previewer
    /// from the extension ALONE, so an extension for the resolved content type is
    /// appended whenever the name has none, or the one it has does not describe
    /// the resolved type. The original name is never thrown away — the correct
    /// extension is appended to it, so the user still recognises the file.
    nonisolated static func filename(for attachment: Attachment, contentType: String?) -> String {
        let sanitized = AttachmentSaver.sanitized(attachment.filename)
        let declared = MIMESniffer.normalize(contentType) ?? MIMESniffer.normalize(attachment.contentType)
        guard let declared, let type = UTType(mimeType: declared), let ext = type.preferredFilenameExtension else {
            return sanitized
        }
        let existing = URL(fileURLWithPath: sanitized).pathExtension
        if !existing.isEmpty, let existingType = UTType(filenameExtension: existing), existingType.conforms(to: type) {
            return sanitized
        }
        // `sanitized` is already clamped to 255; the extension has to fit INSIDE
        // that, or the write fails with a name longer than the filesystem allows.
        let base = String(sanitized.prefix(255 - ext.count - 1))
        return "\(base).\(ext)"
    }
}

/// How long a dragged file stays pinned after the item provider hands it over:
/// the receiver copies it asynchronously and never tells us when it is done.
private nonisolated let dragPinGrace: TimeInterval = 30

/// Drag-out to Finder.
enum AttachmentDrag {
    /// An item provider that downloads on drop rather than on pickup.
    ///
    /// `NSItemProvider(contentsOf:)` needs the file to exist when the drag STARTS,
    /// which would mean downloading every attachment the user merely brushes past.
    /// Registering a file representation instead defers the download to the moment
    /// Finder actually asks for the bytes.
    static func itemProvider(for attachment: Attachment, api: any MailAPIClient) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = AttachmentSaver.sanitized(attachment.filename)
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.data.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1)
            let task = Task {
                defer { progress.completedUnitCount = 1 }
                do {
                    // Pinned across the hand-off: the receiver copies the file
                    // asynchronously after `completion`, and an eviction in that
                    // window would delete the file out from under the copy. The
                    // pin is dropped after a grace period, not at `completion`.
                    let url = try await AttachmentFile.shared.url(for: attachment, using: api, pinned: true)
                    // Detached, and never cancelled with the drag: cancelling the
                    // unpin would leak the pin and wedge the cache at its limit.
                    Task.detached {
                        try? await Task.sleep(for: .seconds(dragPinGrace))
                        await AttachmentFile.shared.unpin(attachment.id)
                    }
                    // `false`: the file is the cache's, not the drop's, so the
                    // receiver must copy it rather than move it out from under us.
                    completion(url, false, nil)
                } catch {
                    logger.error(
                        "Attachment \(attachment.id, privacy: .public) drag failed: \(error.localizedDescription, privacy: .private)"
                    )
                    completion(nil, false, error)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }
}
