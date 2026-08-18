import Foundation

/// Pure, synchronous prefill rules for reply / reply-all / forward.
///
/// Everything here is `nonisolated` and side-effect free so the actor, the
/// view-model and the tests can all call it directly.
public nonisolated enum ComposePrefill {
    // MARK: - Recipients

    /// Recipients for a reply.
    ///
    /// - `to` is the original sender; on reply-all the original `to` follows.
    /// - `cc` is the original `cc` (reply-all only).
    /// - The user's own addresses are dropped, duplicates collapse
    ///   case-insensitively, and the surviving order is the original order.
    /// - Replying to a message you sent yourself keeps the original recipients,
    ///   otherwise the reply would have nowhere to go.
    public static func replyRecipients(
        to message: MessageDetail,
        replyAll: Bool,
        ownAddresses: [String]
    ) -> (to: [String], cc: [String]) {
        let own = Set(ownAddresses.map { $0.lowercased() })
        func strip(_ addresses: [String]) -> [String] {
            EmailAddress.dedupe(addresses.filter { !own.contains($0.lowercased()) })
        }

        let sender = message.summary.fromAddress
        var to = strip(replyAll ? [sender] + message.summary.to : [sender])
        if to.isEmpty {
            // Own message (or sender is us): reply to whoever it went to.
            to = EmailAddress.dedupe(message.summary.to)
        }
        guard replyAll else { return (to, []) }

        let inTo = Set(to.map { $0.lowercased() })
        let cc = strip(message.cc).filter { !inTo.contains($0.lowercased()) }
        return (to, cc)
    }

    // MARK: - Subject

    private static let replyPrefixes = ["re:"]
    private static let forwardPrefixes = ["fwd:", "fw:"]

    /// `"x"` → `"Re: x"`, `"Re: Re: x"` → `"Re: x"`, `"RE: x"` → unchanged.
    /// Forward prefixes are left alone (`"Fwd: x"` → `"Re: Fwd: x"`), which is
    /// what every other client does and what the thread history should read like.
    public static func replySubject(_ subject: String) -> String {
        prefixed(subject, with: "Re:", collapsing: replyPrefixes)
    }

    /// `"x"` → `"Fwd: x"`, `"Fwd: Fwd: x"` → `"Fwd: x"`, `"FW: x"` → unchanged.
    public static func forwardSubject(_ subject: String) -> String {
        prefixed(subject, with: "Fwd:", collapsing: forwardPrefixes)
    }

    private static func prefixed(_ subject: String, with prefix: String, collapsing prefixes: [String]) -> String {
        var rest = Substring(subject).trimmed()
        var existing: Substring?
        while let match = leadingPrefix(of: rest, in: prefixes) {
            if existing == nil { existing = rest[..<match.upperBound] }
            rest = rest[match.upperBound...].trimmed()
        }
        // Reuse the prefix exactly as the user (or the sender) wrote it, so
        // "RE: x" round-trips unchanged instead of being rewritten to "Re: x".
        let head = existing.map(String.init) ?? prefix
        return rest.isEmpty ? head : "\(head) \(rest)"
    }

    private static func leadingPrefix(of text: Substring, in prefixes: [String]) -> Range<Substring.Index>? {
        for prefix in prefixes {
            if let range = text.range(of: prefix, options: [.caseInsensitive, .anchored]) { return range }
        }
        return nil
    }

    // MARK: - Quoted body

    /// `"On <date>, <sender> wrote:"` followed by the original text, each line
    /// prefixed with `"> "` (empty lines become `">"`, as RFC 3676 quoting does).
    public static func quotedBody(of message: MessageDetail, locale: Locale = .autoupdatingCurrent) -> String {
        let header = quoteHeader(of: message, locale: locale)
        let quoted = message.textBody
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
        return "\(header)\n\(quoted)"
    }

    public static func quoteHeader(of message: MessageDetail, locale: Locale = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.locale = locale
        let date = message.summary.displayDate.formatted(style)
        return "On \(date), \(message.summary.fromAddress) wrote:"
    }

    // MARK: - Whole drafts

    /// A reply (or reply-all) prefilled from `message`.
    public static func reply(
        to message: MessageDetail,
        replyAll: Bool,
        from address: String,
        mailboxID: String? = nil,
        ownAddresses: [String] = [],
        locale: Locale = .autoupdatingCurrent
    ) -> ComposeDraft {
        let recipients = replyRecipients(to: message, replyAll: replyAll, ownAddresses: ownAddresses)
        return ComposeDraft(
            mode: .reply(toMessageID: message.id, replyAll: replyAll),
            mailboxID: mailboxID ?? message.summary.mailboxID,
            fromAddress: address,
            to: recipients.to,
            cc: recipients.cc,
            subject: replySubject(message.summary.subject),
            // The SERVER appends attribution + quoted original on POST /reply
            // (worker/features/send/reply-body.ts) — quoting here doubled the
            // history in the first real run. Send only the authored text.
            body: ""
        )
    }

    /// A composer reopened on an EXISTING server draft.
    ///
    /// Everything comes from `draft.editableContent` — including the `version`
    /// stamp, which rides along inside `serverDraft` and is what lets the very
    /// first autosave `PATCH` instead of creating a second draft.
    ///
    /// The result is deliberately NOT dirty: reopening a draft and closing it
    /// again must not save it, must not bump its version, and must not raise the
    /// "unsaved changes" sheet.
    public static func draft(_ draft: Draft) -> ComposeDraft {
        let content = draft.editableContent
        return ComposeDraft(
            mode: mode(for: content),
            mailboxID: content.mailboxID,
            fromAddress: content.from,
            to: content.to,
            cc: content.cc,
            bcc: content.bcc,
            subject: content.subject,
            body: content.text,
            uploadedAttachments: draft.attachments,
            serverDraft: draft,
            isDirty: false
        )
    }

    /// A stored draft remembers what it was: the server keeps `replyToMessageId`
    /// and `forwardOfMessageId` on the row, and losing them on reopen would send
    /// a reply as a fresh message with no threading.
    private static func mode(for content: DraftInput) -> ComposeMode {
        if let replyTo = content.replyToMessageID {
            // `replyAll` is not stored server-side and only ever shaped the
            // PREFILL, which already happened — the recipients in hand are the
            // truth now.
            return .reply(toMessageID: replyTo, replyAll: false)
        }
        if let forwarded = content.forwardOfMessageID {
            return .forward(messageID: forwarded)
        }
        return .new(mailboxID: content.mailboxID)
    }

    /// A forward prefilled from `message`; recipients are the user's to fill in.
    public static func forward(
        _ message: MessageDetail,
        from address: String,
        mailboxID: String? = nil,
        locale: Locale = .autoupdatingCurrent
    ) -> ComposeDraft {
        ComposeDraft(
            mode: .forward(messageID: message.id),
            mailboxID: mailboxID ?? message.summary.mailboxID,
            fromAddress: address,
            subject: forwardSubject(message.summary.subject),
            // Server quotes the forwarded message too (worker/features/send/forward.ts).
            body: ""
        )
    }
}

nonisolated extension Substring {
    fileprivate func trimmed() -> Substring {
        var slice = self
        while let first = slice.first, first.isWhitespace { slice = slice.dropFirst() }
        while let last = slice.last, last.isWhitespace { slice = slice.dropLast() }
        return slice
    }
}
