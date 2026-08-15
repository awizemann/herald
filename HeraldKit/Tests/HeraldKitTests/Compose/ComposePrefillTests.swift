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
