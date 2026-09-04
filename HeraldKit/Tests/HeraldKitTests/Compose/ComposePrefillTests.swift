import Foundation
import Testing
@testable import HeraldKit

/// Prefill is pure, so these tests are exact-value assertions: order, spelling
/// and whitespace are all part of the contract the compose window depends on.
@Suite struct ComposePrefillTests {
    static let own = ["support@example.com", "Support+alias@example.com"]

    static func detail(
        from sender: String = "ada@example.net",
        to recipients: [String] = ["support@example.com", "bob@example.org"],
        cc: [String] = ["carol@example.org", "BOB@example.org", "support@example.com"],
        subject: String = "Invoice question",
        text: String = "Line one\n\nLine two",
        date: Date = Date(timeIntervalSince1970: 1_770_000_000)
    ) -> MessageDetail {
        MessageDetail(
            summary: MessageSummary(
                id: "msg_01",
                threadID: "thr_09",
                mailboxID: "mbx_support",
                direction: .inbound,
                folder: .inbox,
                fromAddress: sender,
                to: recipients,
                subject: subject,
                snippet: "…",
                receivedAt: date,
                sentAt: nil,
                readAt: nil,
                starredAt: nil,
                hasAttachments: false,
                createdAt: date
            ),
            cc: cc,
            bcc: [],
            deliveredToAddress: "support@example.com",
            textBody: text,
            htmlAvailable: false,
            rfcMessageID: nil,
            inReplyTo: nil,
            references: [],
            attachments: []
        )
    }

    /// Fails if reply ever addresses anyone but the sender (e.g. copies `to`).
    @Test("Reply addresses only the original sender")
    func replyRecipients() {
        let result = ComposePrefill.replyRecipients(to: Self.detail(), replyAll: false, ownAddresses: Self.own)
        #expect(result.to == ["ada@example.net"])
        #expect(result.cc.isEmpty)
    }

    /// Fails on a `Set`-based implementation (order lost), on a dedupe that is
    /// case-sensitive (BOB survives), and on one that keeps our own address.
    @Test("Reply-all keeps order, drops our own address, dedupes case-insensitively")
    func replyAllRecipients() {
        let result = ComposePrefill.replyRecipients(to: Self.detail(), replyAll: true, ownAddresses: Self.own)
        #expect(result.to == ["ada@example.net", "bob@example.org"])
        // carol only: BOB duplicates `to`, support is ours.
        #expect(result.cc == ["carol@example.org"])
    }

    /// Fails if "drop own addresses" is applied blindly: replying to a message we
    /// sent would otherwise produce an empty `to` and an unsendable draft.
    @Test("Replying to our own message falls back to the original recipients")
    func replyToOwnMessage() {
        let mine = Self.detail(from: "support@example.com", to: ["ada@example.net"], cc: [])
        let result = ComposePrefill.replyRecipients(to: mine, replyAll: false, ownAddresses: Self.own)
        #expect(result.to == ["ada@example.net"])
    }

    /// Fails on naive `"Re: " + subject` (prefix stacking) and on a
    /// case-sensitive check that rewrites "RE:" into "Re:".
    @Test("Re:/Fwd: prefixes are idempotent and case-insensitive")
    func subjectPrefixes() {
        #expect(ComposePrefill.replySubject("Invoice") == "Re: Invoice")
        #expect(ComposePrefill.replySubject("Re: Re: Invoice") == "Re: Invoice")
        #expect(ComposePrefill.replySubject("RE: Invoice") == "RE: Invoice")
        #expect(ComposePrefill.replySubject("  re:   Invoice ") == "re: Invoice")
        // A forward prefix is history, not a reply prefix: it stays.
        #expect(ComposePrefill.replySubject("Fwd: Invoice") == "Re: Fwd: Invoice")
        #expect(ComposePrefill.forwardSubject("Invoice") == "Fwd: Invoice")
        #expect(ComposePrefill.forwardSubject("FW: Invoice") == "FW: Invoice")
        #expect(ComposePrefill.forwardSubject("Fwd: Fw: Invoice") == "Fwd: Invoice")
    }

    /// Fails if empty lines lose their quote marker or the header is dropped —
    /// both make the quoted block unreadable once the recipient replies again.
    /// Real-server regression (2026-08-15): HQBase quotes the original itself on
    /// /reply and forward, so a client-side quote produced a doubled history.
    /// Fails if reply/forward prefill ever puts quoted text in the body again.
    @Test func replyAndForwardBodiesCarryNoClientSideQuote() {
        let detail = Self.detail()
        let reply = ComposePrefill.reply(to: detail, replyAll: false, from: "me@example.com")
        let fwd = ComposePrefill.forward(detail, from: "me@example.com")
        #expect(reply.body.isEmpty)
        #expect(fwd.body.isEmpty)
        #expect(!reply.body.contains("wrote:") && !fwd.body.contains("> "))
    }

    /// Display-only preview shown under the compose editor. Must never end up in
    /// `ComposeDraft.body` (see `replyAndForwardBodiesCarryNoClientSideQuote`) —
    /// this is a separate value the view-model surfaces alongside the draft.
    @Test("Quoted preview: reply and reply-all get the attributed quote, forward gets the raw body, new gets nothing")
    func quotedPreview() {
        let detail = Self.detail()
        let reply = ComposePrefill.quotedPreview(
            of: detail,
            mode: .reply(toMessageID: detail.id, replyAll: false),
            locale: Locale(identifier: "en_US_POSIX")
        )
        #expect(reply == ComposePrefill.quotedBody(of: detail, locale: Locale(identifier: "en_US_POSIX")))

        let replyAll = ComposePrefill.quotedPreview(of: detail, mode: .reply(toMessageID: detail.id, replyAll: true))
        #expect(replyAll?.contains("wrote:") == true)

        let forward = ComposePrefill.quotedPreview(of: detail, mode: .forward(messageID: detail.id))
        #expect(forward == detail.textBody)
        // Forward's preview is the RAW body — no attribution header and no
        // client-added "> " quote marks, matching what POST /forward builds.
        #expect(forward?.contains("wrote:") == false)
        #expect(forward?.hasPrefix("> ") == false)

        #expect(ComposePrefill.quotedPreview(of: detail, mode: .new(mailboxID: nil)) == nil)
    }

    @Test("Quoted body carries an attribution header and quotes every line")
    func quotedBody() {
        let quoted = ComposePrefill.quotedBody(of: Self.detail(), locale: Locale(identifier: "en_US_POSIX"))
        let lines = quoted.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first?.hasPrefix("On ") == true)
        #expect(lines.first?.hasSuffix(", ada@example.net wrote:") == true)
        #expect(Array(lines.dropFirst()) == ["> Line one", ">", "> Line two"])
    }

    /// Fails if the reply draft loses the message id the server needs on
    /// `POST /reply`, or forgets it is a reply-all.
    @Test("Reply draft records the mode the send path switches on")
    func replyDraftMode() {
        let draft = ComposePrefill.reply(
            to: Self.detail(),
            replyAll: true,
            from: "support@example.com",
            ownAddresses: Self.own
        )
        #expect(draft.mode == .reply(toMessageID: "msg_01", replyAll: true))
        #expect(draft.mailboxID == "mbx_support")
        #expect(draft.draftInput.replyToMessageID == "msg_01")
        #expect(draft.draftInput.forwardOfMessageID == nil)
    }

    /// Fails if forwards do not set `forwardOfMessageId`, which is how the server
    /// links the forward to its original.
    @Test("Forward draft sets forwardOfMessageId and no recipients")
    func forwardDraft() {
        let draft = ComposePrefill.forward(Self.detail(), from: "support@example.com")
        #expect(draft.mode == .forward(messageID: "msg_01"))
        #expect(draft.to.isEmpty)
        #expect(draft.draftInput.forwardOfMessageID == "msg_01")
        #expect(draft.subject == "Fwd: Invoice question")
    }

    // MARK: - Reopening a stored draft

    /// Fails if reopening a draft loses its version stamp: the first autosave
    /// would then `POST` a SECOND draft instead of `PATCH`ing this one, and the
    /// user would end up with two copies of the same message in the folder.
    @Test("Reopening a draft carries its version stamp into the next save")
    func reopenedDraftKeepsItsVersion() {
        let stored = Draft(
            id: "dft_1",
            version: 4,
            updatedAt: Date(timeIntervalSince1970: 3_000),
            attachments: [DraftAttachment(id: "att_1", filename: "q.txt", contentType: "text/plain", sizeBytes: 3)],
            content: DraftInput(
                mailboxID: "mbx_support",
                from: "support@example.com",
                to: ["ada@example.net"],
                cc: ["billing@example.com"],
                subject: "Quote",
                text: "Here it is."
            )
        )

        let composed = ComposePrefill.draft(stored)

        #expect(composed.serverDraft?.id == "dft_1")
        #expect(composed.draftInput.version == 4, "PATCH without the version is an immediate 409")
        #expect(composed.to == ["ada@example.net"])
        #expect(composed.cc == ["billing@example.com"])
        #expect(composed.subject == "Quote")
        #expect(composed.body == "Here it is.")
        #expect(composed.mailboxID == "mbx_support")
        #expect(composed.uploadedAttachments.map(\.id) == ["att_1"])
        // Fails if reopening marks the draft dirty: closing a draft you only
        // looked at would save it, bump its version and raise the unsaved sheet.
        #expect(!composed.isDirty)
    }

    /// Fails if the stored `replyToMessageId` is dropped on reopen — the draft
    /// would then send through `POST /send` as a fresh message with no threading
    /// and no quoted original, instead of `POST /reply`.
    @Test("A reopened reply draft is still a reply")
    func reopenedReplyKeepsItsMode() {
        let stored = Draft(
            id: "dft_2",
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 3_000),
            attachments: [],
            content: DraftInput(replyToMessageID: "msg_01", from: "support@example.com", subject: "Re: Invoice question")
        )

        let composed = ComposePrefill.draft(stored)

        #expect(composed.mode == .reply(toMessageID: "msg_01", replyAll: false))
        #expect(composed.draftInput.replyToMessageID == "msg_01")
    }

    /// Same for a forward, which the v1 API sends through `POST /send` but only
    /// quotes correctly when `forwardOfMessageId` survives.
    @Test("A reopened forward draft is still a forward")
    func reopenedForwardKeepsItsMode() {
        let stored = Draft(
            id: "dft_3",
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 3_000),
            attachments: [],
            content: DraftInput(forwardOfMessageID: "msg_02", from: "support@example.com", subject: "Fwd: Invoice")
        )

        let composed = ComposePrefill.draft(stored)

        #expect(composed.mode == .forward(messageID: "msg_02"))
        #expect(composed.draftInput.forwardOfMessageID == "msg_02")
    }

    /// Fails on a validator that accepts "a@b" or an address with a space —
    /// both are rejected by the server after a wasted round trip.
    @Test("Address validation catches the typos worth catching")
    func addressValidation() {
        #expect(EmailAddress.isValid("ada@example.net"))
        #expect(EmailAddress.isValid("ada+tag@mail.example.co.uk"))
        #expect(!EmailAddress.isValid("ada@localhost"))
        #expect(!EmailAddress.isValid("ada example.net"))
        #expect(!EmailAddress.isValid("@example.net"))
        #expect(!EmailAddress.isValid("ada@.net"))
        #expect(!EmailAddress.isValid(""))
    }
}
