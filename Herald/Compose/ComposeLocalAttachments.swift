import Foundation
import HeraldKit

/// Local copies of the files attached in THIS compose window session.
///
/// The Mail API has no GET for a draft's attachment, so a composer can only
/// Quick Look or save a file it still has on disk. Each successful upload is
/// COPIED into the attachment scratchpad (while the upload's security scope is
/// held), keyed by the server's attachment id: no security-scoped access has
/// to outlive the upload, and the user's original is never touched. A draft
/// reopened later has no entries, so its cards offer Remove only.
///
/// A value type with no I/O of its own beyond ``stageCopy(of:)``, so the
/// availability rules are assertable without a window.
struct ComposeLocalAttachments {
    private(set) var files: [String: URL] = [:]

    /// The local copy for an attachment, if this session has one AND the
    /// attachment is still on the draft.
    func url(for id: String, in attachments: [DraftAttachment]) -> URL? {
        guard attachments.contains(where: { $0.id == id }) else { return nil }
        return files[id]
    }

    /// Records `copy` against the attachment the upload added: the ids present
    /// `after` but not `before`. Anything other than exactly one new id is
    /// ambiguous, and the copy is handed back to be discarded rather than
    /// guessed onto the wrong card.
    ///
    /// - Returns: the copy when it was NOT recorded (the caller discards it).
    mutating func record(_ copy: URL, before: [DraftAttachment], after: [DraftAttachment]) -> URL? {
        let known = Set(before.map(\.id))
        let added = after.map(\.id).filter { !known.contains($0) }
        guard added.count == 1, let id = added.first, files[id] == nil else { return copy }
        files[id] = copy
        return nil
    }

    /// Drops entries whose attachment has left the draft; returns their files.
    mutating func prune(keeping attachments: [DraftAttachment]) -> [URL] {
        let live = Set(attachments.map(\.id))
        let gone = files.filter { !live.contains($0.key) }
        for id in gone.keys { files[id] = nil }
        return Array(gone.values)
    }

    /// Everything, for the window closing.
    mutating func removeAll() -> [URL] {
        defer { files = [:] }
        return Array(files.values)
    }

    /// Copies a file the user attached into the scratchpad, under its own name.
    /// The caller holds the file's security scope for the duration.
    nonisolated static func stageCopy(of url: URL) throws -> URL {
        try AttachmentScratchpad.prepare()
        let folder = AttachmentScratchpad.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(AttachmentSaver.sanitized(url.lastPathComponent))
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }
}
