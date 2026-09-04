import Foundation

/// What the user is composing, and what the server needs to know about it.
///
/// `.forward` maps to `DraftInput.forwardOfMessageID` while it is a draft, and
/// sends through `POST /forward` (upstream 1.3.4+), which names the forwarded
/// message in the request rather than relying on the draft row.
public nonisolated enum ComposeMode: Sendable, Hashable {
    case new(mailboxID: String?)
    case reply(toMessageID: String, replyAll: Bool)
    case forward(messageID: String)

    /// The message this compose answers, when the server needs it.
    public var replyToMessageID: String? {
        if case .reply(let id, _) = self { return id }
        return nil
    }

    public var forwardOfMessageID: String? {
        if case .forward(let id) = self { return id }
        return nil
    }
}

/// The local editing model for one compose window.
///
/// A value type: the UI owns a copy, ``OutboxService`` returns an updated copy
/// after every server round trip. `isDirty` flips whenever an editable field is
/// mutated and is cleared by a successful save.
public nonisolated struct ComposeDraft: Sendable, Hashable, Identifiable {
    /// Stable local identity; survives the first server save.
    public let id: UUID
    public let mode: ComposeMode
    /// Mailbox the draft belongs to (`nil` until the user picks one).
    public var mailboxID: String? { didSet { markDirty(oldValue != mailboxID) } }
    public var fromAddress: String { didSet { markDirty(oldValue != fromAddress) } }
    public var to: [String] { didSet { markDirty(oldValue != to) } }
    public var cc: [String] { didSet { markDirty(oldValue != cc) } }
    public var bcc: [String] { didSet { markDirty(oldValue != bcc) } }
    public var subject: String { didSet { markDirty(oldValue != subject) } }
    /// Plain-text body. Herald composes text only; the server derives HTML.
    public var body: String { didSet { markDirty(oldValue != body) } }
    /// Files the user picked that are not uploaded yet.
    public private(set) var pendingAttachments: [URL]
    /// Files already uploaded to the server draft.
    public private(set) var uploadedAttachments: [DraftAttachment]
    /// The server-side draft, once ``OutboxService/saveDraft(_:)`` has created one.
    public private(set) var serverDraft: Draft?
    public private(set) var isDirty: Bool

    public init(
        id: UUID = UUID(),
        mode: ComposeMode,
        mailboxID: String? = nil,
        fromAddress: String = "",
        to: [String] = [],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String = "",
        body: String = "",
        pendingAttachments: [URL] = [],
        uploadedAttachments: [DraftAttachment] = [],
        serverDraft: Draft? = nil,
        isDirty: Bool = true
    ) {
        self.id = id
        self.mode = mode
        self.mailboxID = mailboxID ?? mode.newMailboxID
        self.fromAddress = fromAddress
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.pendingAttachments = pendingAttachments
        self.uploadedAttachments = uploadedAttachments
        self.serverDraft = serverDraft
        self.isDirty = isDirty
    }

    private mutating func markDirty(_ changed: Bool) {
        if changed { isDirty = true }
    }

    /// Every address the message will go to, in `to`, `cc`, `bcc` order.
    public var allRecipients: [String] { to + cc + bcc }

    public var attachmentIDs: [String] { uploadedAttachments.map(\.id) }

    /// Body of `POST /drafts` / `PATCH /drafts/{id}`.
    ///
    /// The version stamp comes from ``serverDraft`` — omitting it is what the
    /// server answers with 409, so it is set here rather than at each call site.
    public var draftInput: DraftInput {
        DraftInput(
            mailboxID: mailboxID,
            replyToMessageID: mode.replyToMessageID,
            forwardOfMessageID: mode.forwardOfMessageID,
            from: fromAddress,
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            text: body,
            html: "",
            version: serverDraft?.version
        )
    }

    // MARK: - Mutation used by OutboxService

    public mutating func addPendingAttachment(_ url: URL) {
        guard !pendingAttachments.contains(url) else { return }
        pendingAttachments.append(url)
        isDirty = true
    }

    mutating func applySaved(_ draft: Draft) {
        serverDraft = draft
        uploadedAttachments = draft.attachments
        isDirty = false
    }

    mutating func applyUpload(_ attachment: DraftAttachment, from url: URL?) {
        if let url { pendingAttachments.removeAll { $0 == url } }
        if let index = uploadedAttachments.firstIndex(where: { $0.id == attachment.id }) {
            uploadedAttachments[index] = attachment
        } else {
            uploadedAttachments.append(attachment)
        }
    }

    mutating func applyRemoval(attachmentID: String) {
        uploadedAttachments.removeAll { $0.id == attachmentID }
    }

    mutating func clearServerDraft() {
        serverDraft = nil
    }

    /// The fields the USER owns. Compared rather than copied, so a round trip can
    /// never be the thing that changes what is on screen.
    public func hasSameEditableContent(as other: ComposeDraft) -> Bool {
        mailboxID == other.mailboxID
            && fromAddress == other.fromAddress
            && to == other.to
            && cc == other.cc
            && bcc == other.bcc
            && subject == other.subject
            && body == other.body
    }

    /// Merges a server response into the draft the window is still editing,
    /// taking ONLY the fields the server owns (draft identity/version and the
    /// attachment list).
    ///
    /// Assigning the whole response back — `draft = try await save(draft)` — is a
    /// data-loss bug twice over: it reverts anything typed during the round trip,
    /// and a server that normalizes (trims a subject, rewrites the body) makes the
    /// draft dirty again on every save, i.e. an autosave loop.
    ///
    /// - Parameters:
    ///   - saved: what the outbox returned.
    ///   - sent: the snapshot handed to the outbox. The difference between it and
    ///     `self` is what the user typed while the save ran, and is what decides
    ///     whether the draft is still dirty.
    public mutating func adoptServerState(from saved: ComposeDraft, sent: ComposeDraft) {
        serverDraft = saved.serverDraft
        uploadedAttachments = saved.uploadedAttachments
        // Keep a pending file only if the server still calls it pending, or if it
        // was picked after `sent` was taken (this response says nothing about it).
        pendingAttachments = pendingAttachments.filter { url in
            saved.pendingAttachments.contains(url) || !sent.pendingAttachments.contains(url)
        }
        isDirty = !hasSameEditableContent(as: sent) || !pendingAttachments.isEmpty
    }
}

nonisolated extension ComposeMode {
    fileprivate var newMailboxID: String? {
        if case .new(let mailboxID) = self { return mailboxID }
        return nil
    }
}

/// Deliberately small address check: enough to stop obvious typos before a
/// round trip, never strict enough to reject a legal address the server accepts.
public nonisolated enum EmailAddress {
    public static func isValid(_ address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 320 else { return false }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
        return !domain.contains("..")
    }

    /// Case-insensitive dedupe that preserves both order and original spelling.
    public static func dedupe(_ addresses: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for address in addresses {
            let key = address.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(address)
        }
        return result
    }
}
