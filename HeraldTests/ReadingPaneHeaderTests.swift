import Foundation
import HeraldKit
import Testing
@testable import Herald

/// `ReadingPaneMessagePosition` and `ReadingPaneMailboxAddress`: the reading
/// pane's "Message N of M" line and its To/From address chip — both pure
/// derivations over `MailViewModel`'s existing thread/mailbox state.
@Suite("Reading pane header", .scratchDefaults)
struct ReadingPaneHeaderTests {
    static let epoch = Date(timeIntervalSince1970: 0)

    static func message(
        id: String,
        mailboxID: String? = "mbx1",
        folder: MailFolder = .inbox
    ) -> MessageSummary {
        MessageSummary(
            id: id, threadID: "thr1", mailboxID: mailboxID, direction: .inbound, folder: folder,
            fromAddress: "sender@example.com", to: ["me@example.com"], subject: "Subject", snippet: "…",
            receivedAt: epoch, sentAt: nil, readAt: epoch, starredAt: nil, hasAttachments: false, createdAt: epoch
        )
    }

    static func mailbox(id: String, address: String, mailDomainID: String) -> Mailbox {
        Mailbox(
            id: id, address: address,
            addresses: [
                MailboxAddress(
                    id: "adr_\(id)", mailboxID: id, mailDomainID: mailDomainID, address: address,
                    displayName: "", receiveEnabled: true, sendEnabled: true, isPrimary: true
                ),
            ],
            displayName: "", isActive: true, accessLevel: .manager, createdAt: epoch, updatedAt: epoch
        )
    }

    // MARK: - ReadingPaneMessagePosition

    @Test("Not showing a drilled-in thread: nil, even with a selected message")
    func nilWhenNotShowingThread() {
        let messages = [Self.message(id: "m3"), Self.message(id: "m2"), Self.message(id: "m1")]
        let result = ReadingPaneMessagePosition.resolve(
            threadMessages: messages, selectedMessageID: "m2", isShowingThread: false
        )
        #expect(result == nil)
    }

    @Test("A single-message conversation never shows a position, even if isShowingThread were somehow true")
    func singleMessageStillCountsWhenAsked() {
        // `isShowingThread` never actually goes true for a one-message
        // conversation (MailViewModel.showThread's own guard) — this only
        // pins that the pure math itself does not special-case count 1 away,
        // so the guard staying correct is what keeps it hidden in practice.
        let messages = [Self.message(id: "m1")]
        let result = ReadingPaneMessagePosition.resolve(
            threadMessages: messages, selectedMessageID: "m1", isShowingThread: true
        )
        #expect(result?.position == 1)
        #expect(result?.total == 1)
    }

    @Test("N counts oldest-first: the newest (index 0) is M of M")
    func newestIsMOfM() {
        let messages = [Self.message(id: "newest"), Self.message(id: "mid"), Self.message(id: "oldest")]
        let result = ReadingPaneMessagePosition.resolve(
            threadMessages: messages, selectedMessageID: "newest", isShowingThread: true
        )
        #expect(result?.position == 3)
        #expect(result?.total == 3)
    }

    @Test("The oldest message (last in the newest-first array) is 1 of M")
    func oldestIsOneOfM() {
        let messages = [Self.message(id: "newest"), Self.message(id: "mid"), Self.message(id: "oldest")]
        let result = ReadingPaneMessagePosition.resolve(
            threadMessages: messages, selectedMessageID: "oldest", isShowingThread: true
        )
        #expect(result?.position == 1)
        #expect(result?.total == 3)
    }

    @Test("A middle message lands between the two ends")
    func middleMessagePosition() {
        let messages = [Self.message(id: "newest"), Self.message(id: "mid"), Self.message(id: "oldest")]
        let result = ReadingPaneMessagePosition.resolve(
            threadMessages: messages, selectedMessageID: "mid", isShowingThread: true
        )
        #expect(result?.position == 2)
        #expect(result?.total == 3)
    }

    @Test("A selected id absent from threadMessages resolves to nil rather than crashing")
    func missingSelectionIsNil() {
        let messages = [Self.message(id: "m1"), Self.message(id: "m2")]
        let result = ReadingPaneMessagePosition.resolve(
            threadMessages: messages, selectedMessageID: "ghost", isShowingThread: true
        )
        #expect(result == nil)
    }

    @Test("label(_:) formats exactly 'Message N of M', and nil formats to nil")
    func labelFormatting() {
        #expect(ReadingPaneMessagePosition.label((position: 2, total: 5)) == "Message 2 of 5")
        #expect(ReadingPaneMessagePosition.label(nil) == nil)
    }

    // MARK: - ReadingPaneMailboxAddress

    @Test("Inbox and Archived show 'To'")
    func toWordForReceivingFolders() {
        #expect(ReadingPaneMailboxAddress.word(for: .inbox) == "To")
        #expect(ReadingPaneMailboxAddress.word(for: .archived) == "To")
        #expect(ReadingPaneMailboxAddress.word(for: .trash) == "To")
    }

    @Test("Sent and Drafts show 'From'")
    func fromWordForSendingFolders() {
        #expect(ReadingPaneMailboxAddress.word(for: .sent) == "From")
        #expect(ReadingPaneMailboxAddress.word(for: .drafts) == "From")
    }

    @Test("Resolves to the mailbox's own address, badged with its domain")
    func resolvesMailboxAddressAndBadge() {
        let defaults = ScratchDefaults.make()
        let mailboxes = [Self.mailbox(id: "mbx1", address: "sales@acme.co", mailDomainID: "dom-acme")]
        let message = Self.message(id: "m1", mailboxID: "mbx1", folder: .inbox)
        let info = ReadingPaneMailboxAddress.resolve(for: message, mailboxes: mailboxes, accountID: "acct", in: defaults)
        #expect(info.word == "To")
        #expect(info.address == "sales@acme.co")
        #expect(info.badge?.monogram == "AC")
    }

    @Test("A Sent message resolves 'From' with the same owning-mailbox address")
    func sentMessageShowsFrom() {
        let defaults = ScratchDefaults.make()
        let mailboxes = [Self.mailbox(id: "mbx1", address: "sales@acme.co", mailDomainID: "dom-acme")]
        let message = Self.message(id: "m1", mailboxID: "mbx1", folder: .sent)
        let info = ReadingPaneMailboxAddress.resolve(for: message, mailboxes: mailboxes, accountID: "acct", in: defaults)
        #expect(info.word == "From")
        #expect(info.address == "sales@acme.co")
    }

    @Test("A message with no mailboxID (an unassigned catch-all) reads 'No mailbox' with no badge")
    func noMailboxIDHasNoBadge() {
        let defaults = ScratchDefaults.make()
        let message = Self.message(id: "m1", mailboxID: nil, folder: .inbox)
        let info = ReadingPaneMailboxAddress.resolve(for: message, mailboxes: [], accountID: "acct", in: defaults)
        #expect(info.address == "No mailbox")
        #expect(info.badge == nil)
    }

    @Test("A mailboxID absent from the account's mailboxes also falls back rather than crashing")
    func unknownMailboxIDFallsBack() {
        let defaults = ScratchDefaults.make()
        let message = Self.message(id: "m1", mailboxID: "ghost", folder: .inbox)
        let info = ReadingPaneMailboxAddress.resolve(for: message, mailboxes: [], accountID: "acct", in: defaults)
        #expect(info.address == "No mailbox")
        #expect(info.badge == nil)
    }
}
