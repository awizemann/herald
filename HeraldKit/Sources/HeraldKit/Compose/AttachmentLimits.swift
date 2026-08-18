import Foundation

/// What a draft may carry, mirrored from the server's own rules.
///
/// The v1 spec advertises no limits, but the worker enforces three
/// (`worker/features/drafts/queries.ts`): 25 MiB per file, 25 MiB per draft in
/// total, and at most 20 attachments — a breach is a 413 `ATTACHMENTS_TOO_LARGE`
/// *after* the whole file has gone up the wire. Herald mirrors them so the user
/// learns before the upload rather than after it.
///
/// A value type (not three constants) so tests can shrink the limits to bytes
/// instead of writing 25 MiB of zeroes to disk to prove a boundary.
public nonisolated struct AttachmentLimits: Sendable, Hashable {
    /// Largest single file, in bytes.
    public let perFileBytes: Int
    /// Largest total of all uploaded attachments on one draft, in bytes.
    public let perDraftBytes: Int
    /// Most attachments one draft may carry.
    public let maxCount: Int

    public init(perFileBytes: Int, perDraftBytes: Int, maxCount: Int) {
        self.perFileBytes = perFileBytes
        self.perDraftBytes = perDraftBytes
        self.maxCount = maxCount
    }

    /// The server's limits, to the byte. Deliberately not stricter: a client cap
    /// below the server's just makes Herald refuse mail the account can send.
    public static let server = AttachmentLimits(
        perFileBytes: 25 * 1_024 * 1_024,
        perDraftBytes: 25 * 1_024 * 1_024,
        maxCount: 20
    )

    /// Checks one candidate file against all three limits at once.
    ///
    /// - Parameters:
    ///   - bytes: size of the file about to be uploaded.
    ///   - existing: the attachments already on the draft.
    /// - Returns: the error to throw, or `nil` when the file fits.
    public func rejection(forAdding bytes: Int, to existing: [DraftAttachment]) -> OutboxError? {
        if existing.count >= maxCount {
            return .tooManyAttachments(limit: maxCount)
        }
        if bytes > perFileBytes {
            return .attachmentTooLarge(bytes: bytes, limit: perFileBytes)
        }
        let total = existing.reduce(0) { $0 + $1.sizeBytes } + bytes
        if total > perDraftBytes {
            return .draftTooLarge(bytes: total, limit: perDraftBytes)
        }
        return nil
    }
}
