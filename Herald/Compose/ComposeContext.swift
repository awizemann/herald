import Foundation
import HeraldKit

/// Everything one compose window needs to build its draft, resolved once by the
/// view-model that owns the mail data and then handed to the window.
///
/// A value type so the window can be re-created (state restoration, reopen)
/// without reaching back into the mail UI, and so the prefill rules can be
/// tested without a window at all.
nonisolated struct ComposeContext: Sendable, Identifiable {
    let id: UUID
    let kind: ComposeRequest.Kind
    let mailboxID: String?
    /// The address the message is sent from.
    let fromAddress: String
    /// Every address this account owns; reply-all drops them so the user is not
    /// a recipient of their own reply.
    let ownAddresses: [String]
    /// The message being replied to or forwarded (`nil` for a new message).
    let message: MessageDetail?
    /// The stored draft being reopened (`.draft` only). Resolved from the CACHE,
    /// so opening a draft from the folder costs no round trip.
    let storedDraft: Draft?

    init(
        id: UUID = UUID(),
        kind: ComposeRequest.Kind,
        mailboxID: String? = nil,
        fromAddress: String = "",
        ownAddresses: [String] = [],
        message: MessageDetail? = nil,
        storedDraft: Draft? = nil
    ) {
        self.id = id
        self.kind = kind
        self.mailboxID = mailboxID
        self.fromAddress = fromAddress
        self.ownAddresses = ownAddresses
        self.message = message
        self.storedDraft = storedDraft
    }

    /// The draft this context opens with.
    func makeDraft() -> ComposeDraft {
        switch kind {
        case .draft:
            guard let storedDraft else { break }
            return ComposePrefill.draft(storedDraft)
        case .reply, .replyAll:
            guard let message else { break }
            return ComposePrefill.reply(
                to: message,
                replyAll: kind == .replyAll,
                from: fromAddress,
                mailboxID: mailboxID,
                ownAddresses: ownAddresses
            )
        case .forward:
            guard let message else { break }
            return ComposePrefill.forward(message, from: fromAddress, mailboxID: mailboxID)
        case .new:
            break
        }
        // No message to answer (or a new message): an empty draft, never a crash.
        return ComposeDraft(mode: .new(mailboxID: mailboxID), mailboxID: mailboxID, fromAddress: fromAddress)
    }
}
