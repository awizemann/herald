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
    private(set) var lastSaved: ComposeDraft?
    private var sendError: OutboxError?
    /// Stands in for a server that normalises what it is given.
    private var normalize: (@Sendable (ComposeDraft) -> ComposeDraft)?

    func setSendError(_ error: OutboxError?) { sendError = error }

    func setNormalizer(_ normalize: (@Sendable (ComposeDraft) -> ComposeDraft)?) {
        self.normalize = normalize
    }

    @discardableResult
    func saveDraft(_ draft: ComposeDraft) async throws(OutboxError) -> ComposeDraft {
        saveCount += 1
        lastSaved = draft
        return normalize?(draft) ?? draft
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
        // Real-run regression: the post-send dismissal must not prompt to save —
        // fails if a sent composer still reports unsaved work.
        #expect(!model.hasUnsavedChanges)
    }

    /// A server that normalises the body (or a save that lands after the user has
    /// typed on) used to have its whole response assigned over the local draft:
    /// the text on screen changed under the user, and the draft came back dirty,
    /// so the next autosave saved and normalised again — forever. Fails if the
    /// response's body reaches the composer, or if the draft stays dirty.
    @Test func aNormalizingSaveNeitherRewritesTheTextNorLoopsTheAutosave() async {
        let outbox = FakeOutbox()
        await outbox.setNormalizer { draft in
            var normalized = draft
            normalized.body = "SERVER REWROTE THIS"
            normalized.subject = draft.subject.uppercased()
            return normalized
        }
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: outbox,
            autosaveDelay: .zero
        )

        model.toText = "friend@example.com"
        model.subject = "Lunch"
        model.bodyText = "What the user typed"
        await model.waitForAutosave()

        #expect(model.bodyText == "What the user typed")
        #expect(model.draft.body == "What the user typed")
        #expect(model.subject == "Lunch")
        #expect(model.draft.isDirty == false, "A normalizing response left the draft dirty: autosave loop")
        #expect(model.hasUnsavedChanges == false)

        // And the loop's second lap never happens: nothing is dirty to save.
        let saves = await outbox.saveCount
        await model.saveNow()
        #expect(await outbox.saveCount == saves)
    }

    /// Closing a window inside the autosave debounce — which is most closes, the
    /// last thing a user does being to type — used to cancel the pending save and
    /// lose everything since the previous one. Fails if `flushAndStop` does not
    /// save, and would pass trivially if `stop()` did (it does not: the control
    /// below proves the debounce is still pending).
    @Test func closingDuringTheDebounceFlushesThePendingSave() async {
        let stopped = FakeOutbox()
        let control = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: stopped,
            autosaveDelay: .seconds(3600)
        )
        control.subject = "Half-written"
        control.stop()
        #expect(await stopped.saveCount == 0, "stop() saved; this test would prove nothing")

        let outbox = FakeOutbox()
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: outbox,
            autosaveDelay: .seconds(3600)
        )
        model.subject = "Half-written"
        model.bodyText = "and not yet saved"

        await model.flushAndStop()

        #expect(await outbox.saveCount == 1)
        #expect(await outbox.lastSaved?.body == "and not yet saved")
        #expect(model.draft.isDirty == false)

        // Idempotent: a second close does not save an unchanged draft again.
        await model.flushAndStop()
        #expect(await outbox.saveCount == 1)
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

    /// Fails if the quoted preview leaks into the outgoing body (would double the
    /// server's own quote on `POST /reply`/`POST /forward`) or is missing for the
    /// modes that should show one.
    @Test func quotedPreviewIsDisplayOnlyAndNeverJoinsTheOutgoingBody() async throws {
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        let detail = MessageDetail(
            summary: MessageSummary(
                id: "msg_01",
                threadID: "thr_09",
                mailboxID: "mbx_support",
                direction: .inbound,
                folder: .inbox,
                fromAddress: "ada@example.net",
                to: ["me@example.com"],
                subject: "Invoice question",
                snippet: "…",
                receivedAt: date,
                sentAt: nil,
                readAt: nil,
                starredAt: nil,
                hasAttachments: false,
                createdAt: date
            ),
            cc: [],
            bcc: [],
            deliveredToAddress: "me@example.com",
            textBody: "Line one\n\nLine two",
            htmlAvailable: false,
            rfcMessageID: nil,
            inReplyTo: nil,
            references: [],
            attachments: []
        )
        let outbox = FakeOutbox()

        let replyContext = ComposeContext(kind: .reply, fromAddress: "me@example.com", message: detail)
        let replyModel = ComposeViewModel(context: replyContext, outbox: outbox)
        #expect(replyModel.quotedPreview?.contains("wrote:") == true)
        #expect(replyModel.draft.body.isEmpty)
        #expect(replyModel.bodyText.isEmpty)

        let forwardContext = ComposeContext(kind: .forward, fromAddress: "me@example.com", message: detail)
        let forwardModel = ComposeViewModel(context: forwardContext, outbox: outbox)
        #expect(forwardModel.quotedPreview == detail.textBody)
        #expect(forwardModel.draft.body.isEmpty)

        forwardModel.toText = "someone@example.com"
        forwardModel.bodyText = "See below"
        _ = await forwardModel.send()
        let sentForward = await outbox.lastSent
        // The ONLY thing that reaches the outbox is the authored text — the
        // preview must never be appended to it.
        #expect(sentForward?.body == "See below")
        #expect(sentForward?.body.contains(detail.textBody) == false)

        // Same invariant on the reply path, which shows a DIFFERENT preview
        // (attributed quote, not the raw body) — checked separately since a
        // leak here would double the server's own quote too.
        replyModel.bodyText = "Thanks!"
        _ = await replyModel.send()
        let sentReply = await outbox.lastSent
        #expect(sentReply?.body == "Thanks!")
        #expect(sentReply?.body.contains("wrote:") == false)

        let newContext = ComposeContext(kind: .new, fromAddress: "me@example.com")
        let newModel = ComposeViewModel(context: newContext, outbox: outbox)
        #expect(newModel.quotedPreview == nil)
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
