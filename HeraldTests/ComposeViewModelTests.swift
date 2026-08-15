import Foundation
import HeraldKit
import Testing
@testable import Herald

/// Records what the composer asked the outbox to do and can be told to fail.
///
/// An actor, like the real ``OutboxService``, which is why ``Outboxing`` had to
/// be extracted as a `nonisolated protocol`.
actor FakeOutbox: Outboxing {
    private(set) var saveCount = 0
    private(set) var sendCount = 0
    private(set) var discardCount = 0
    private(set) var lastSent: ComposeDraft?
    private var sendError: OutboxError?

    func setSendError(_ error: OutboxError?) { sendError = error }

    @discardableResult
    func saveDraft(_ draft: ComposeDraft) async throws(OutboxError) -> ComposeDraft {
        saveCount += 1
        return draft
    }

    func discard(_ draft: ComposeDraft) async throws(OutboxError) { discardCount += 1 }

    func attach(_ fileURL: URL, to draft: ComposeDraft) async throws(OutboxError) -> ComposeDraft { draft }

    func removeAttachment(
        _ attachmentID: String,
        from draft: ComposeDraft
    ) async throws(OutboxError) -> ComposeDraft {
        _ = attachmentID
        return draft
    }

    @discardableResult
    func send(_ draft: ComposeDraft) async throws(OutboxError) -> MessageSummary {
        sendCount += 1
        lastSent = draft
        if let sendError { throw sendError }
        return MailFixtures.message(id: "sent")
    }
}

@MainActor
@Suite struct ComposeViewModelTests {
    /// Fails if autosave runs per keystroke (2 saves) or never fires (0).
    @Test func autosaveDebouncesBurstsIntoOneSave() async {
        let outbox = FakeOutbox()
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: outbox,
            autosaveDelay: .zero
        )

        model.subject = "Hel"
        model.subject = "Hello"
        await model.waitForAutosave()

        #expect(await outbox.saveCount == 1)
    }

    /// Fails if a malformed address is shipped to the server anyway, or if the
    /// error never reaches the field the user has to fix.
    @Test func sendWithInvalidRecipientNeverReachesTheOutbox() async {
        let outbox = FakeOutbox()
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: outbox,
            // Long delay: this test must observe send(), not an autosave.
            autosaveDelay: .seconds(3600)
        )
        model.toText = "not-an-email"
        model.subject = "Hi"

        let sent = await model.send()

        #expect(sent == false)
        #expect(await outbox.sendCount == 0)
        #expect(await outbox.saveCount == 0)
        #expect(model.invalid(.to) == ["not-an-email"])
        #expect(model.hint(for: .to) != nil)
        #expect(model.status.message != nil)
    }

    /// Fails if a failed send closes the window (the user's text would be gone)
    /// or if a successful send leaves it open.
    @Test func sendFailureKeepsTheWindowAndSuccessClosesIt() async {
        let outbox = FakeOutbox()
        await outbox.setSendError(.api(.unauthorized))
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: outbox,
            autosaveDelay: .seconds(3600)
        )
        model.toText = "friend@example.com"
        model.bodyText = "Text the user must not lose"

        #expect(await model.send() == false)
        #expect(model.isClosed == false)
        #expect(model.status.message != nil)
        #expect(model.bodyText == "Text the user must not lose")

        await outbox.setSendError(nil)
        #expect(await model.send() == true)
        #expect(model.isClosed)
    }

    /// Fails if the view-model hands the composer empty own-addresses: the user's
    /// own address would survive reply-all and they would CC themselves.
    @Test func replyAllDropsTheAccountsOwnAddress() async throws {
        let store = try MailStore.inMemory()
        let api = FakeMailAPIClient()
        let (stream, _) = AsyncStream<SyncEvent>.makeStream()
        let mail = MailViewModel(
            accountID: "acct",
            accountLabel: "Test",
            api: api,
            store: store,
            actions: MailActionService(api: api, store: store),
            events: stream
        )
        try await store.upsertMailboxes([Self.mailbox], accountID: "acct")
        await api.setDetail(Self.incoming)
        await mail.reloadMailboxes()

        let request = ComposeRequest(kind: .replyAll, messageID: "m1", mailboxID: "mbA")
        let context = try #require(await mail.composeContext(for: request))
        let model = ComposeViewModel(context: context, outbox: FakeOutbox())

        #expect(context.ownAddresses.contains("me@example.com"))
        #expect(model.draft.to == ["other@example.com", "friend@example.com"])
        #expect(model.draft.allRecipients.contains("me@example.com") == false)
        #expect(model.draft.subject == "Re: Standup")
        #expect(model.windowTitle == "Re: Standup")
    }

    private static let mailbox = Mailbox(
        id: "mbA",
        address: "me@example.com",
        addresses: [
            MailboxAddress(
                id: "addr1",
                mailboxID: "mbA",
                mailDomainID: "dom",
                address: "me@example.com",
                displayName: "Me",
                receiveEnabled: true,
                sendEnabled: true,
                isPrimary: true
            )
        ],
        displayName: "Me",
        isActive: true,
        accessLevel: .manager,
        createdAt: MailFixtures.epoch,
        updatedAt: MailFixtures.epoch
    )

    private static let incoming = MessageDetail(
        summary: MessageSummary(
            id: "m1",
            threadID: "t1",
            mailboxID: "mbA",
            direction: .inbound,
            folder: .inbox,
            fromAddress: "other@example.com",
            to: ["me@example.com", "friend@example.com"],
            subject: "Standup",
            snippet: "snippet",
            receivedAt: MailFixtures.epoch,
            sentAt: nil,
            readAt: nil,
            starredAt: nil,
            hasAttachments: false,
            createdAt: MailFixtures.epoch
        ),
        cc: [],
        bcc: [],
        deliveredToAddress: "me@example.com",
        textBody: "body",
        htmlAvailable: false,
        rfcMessageID: nil,
        inReplyTo: nil,
        references: [],
        attachments: []
    )
}
