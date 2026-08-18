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
    private static let cacheLimit = 16

    private var staged: [String: URL] = [:]
    /// Attachment ids in least-recently-staged order; the eviction queue.
    private var order: [String] = []
    private var inFlight: [String: Task<URL, any Error>] = [:]

    /// The local file for an attachment, downloading it if this is the first ask.
    ///
    /// The file is quarantined: it came off the network, and the user may well
    /// drag it straight into Finder and double-click it.
    func url(for attachment: Attachment, using api: any MailAPIClient) async throws -> URL {
        if let existing = staged[attachment.id], FileManager.default.fileExists(atPath: existing.path) {
            return existing
        }
        if let running = inFlight[attachment.id] {
            return try await running.value
        }
        // The bookkeeping happens INSIDE the task, not around the `await`: a caller
        // that cancels (a Finder drag let go early) would otherwise clear `inFlight`
        // while this download keeps running, so the file it writes is never
        // recorded — leaked for the launch — and the next ask downloads it again.
        let task = Task<URL, any Error> { [api] in
            do {
                let payload = try await api.attachmentData(id: attachment.id)
                let filename = Self.filename(for: attachment, contentType: payload.mimeType)
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
        return try await task.value
    }

    private func finish(_ id: String, with url: URL?) {
        if let url {
            staged[id] = url
            order.removeAll { $0 == id }
            order.append(id)
            // Herald is left open for weeks; without an eviction the previewed
            // attachments of every message read in that time stay on disk at up
            // to 25 MiB each. The cache is a convenience, not a store.
            while order.count > Self.cacheLimit, let oldest = order.first {
                order.removeFirst()
                if let stale = staged.removeValue(forKey: oldest) { AttachmentScratchpad.discard(stale) }
            }
        }
        inFlight[id] = nil
    }

    /// A filename Quick Look and Finder can act on.
    ///
    /// The server's `filename` is attacker-influenced and sometimes extension-less
    /// (the v1 multipart upload declares no per-part type, so many attachments come
    /// back as `application/octet-stream`); an extension derived from the response's
    /// content type is appended only when the name has none, because Quick Look
    /// picks its previewer from the extension alone.
    nonisolated static func filename(for attachment: Attachment, contentType: String?) -> String {
        let sanitized = AttachmentSaver.sanitized(attachment.filename)
        guard URL(fileURLWithPath: sanitized).pathExtension.isEmpty else { return sanitized }
        let declared = contentType ?? attachment.contentType
        let type = declared.split(separator: ";").first.map(String.init) ?? declared
        guard let ext = UTType(mimeType: type.trimmingCharacters(in: .whitespaces))?.preferredFilenameExtension else {
            return sanitized
        }
        // `sanitized` is already clamped to 255; the extension has to fit INSIDE
        // that, or the write fails with a name longer than the filesystem allows.
        let base = String(sanitized.prefix(255 - ext.count - 1))
        return "\(base).\(ext)"
    }
}

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
                    let url = try await AttachmentFile.shared.url(for: attachment, using: api)
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
