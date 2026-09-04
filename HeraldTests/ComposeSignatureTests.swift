import Foundation
import HeraldKit
import Testing
@testable import Herald

/// The compose window's half of signatures: which one is picked by default, what
/// the picker offers, what switching does, and what the preview shows.
///
/// The preview is DISPLAY ONLY. The server appends the signature itself
/// (`assembleMessageBody`), so a composer that folded the preview into the body
/// would send it twice — the same failure the quoted-original preview avoids.
@MainActor
@Suite struct ComposeSignatureTests {
    private static let mailboxSignature = Signature(
        id: "sig_mailbox",
        name: "Support",
        html: "<p>Support Team</p>",
        text: "Support Team",
        scope: .mailbox,
        scopeID: "mbx_support",
        scopeLabel: "support@example.com",
        isDefault: true,
        createdAt: MailFixtures.epoch,
        updatedAt: MailFixtures.epoch
    )

    private static let personalSignature = Signature(
        id: "sig_personal",
        name: "Ada",
        html: "<p>Ada Lovelace</p>",
        text: "Ada Lovelace",
        scope: .user,
        scopeID: "usr_1",
        scopeLabel: "Ada",
        isDefault: false,
        createdAt: MailFixtures.epoch,
        updatedAt: MailFixtures.epoch
    )

    private static let candidates = SignatureCandidates(
        automaticSignatureID: "sig_mailbox",
        signatures: [mailboxSignature, personalSignature]
    )

    private static func model(
        _ outbox: FakeOutbox,
        kind: ComposeRequest.Kind = .new,
        storedDraft: Draft? = nil
    ) -> ComposeViewModel {
        ComposeViewModel(
            context: ComposeContext(
                kind: kind,
                mailboxID: "mbx_support",
                fromAddress: "support@example.com",
                storedDraft: storedDraft
            ),
            outbox: outbox,
            // Long: these tests assert selection state, never the debounce.
            autosaveDelay: .seconds(3600)
        )
    }

    private static func storedDraft(_ signature: SignatureSnapshot) -> Draft {
        Draft(
            id: "drf_1",
            version: 3,
            updatedAt: MailFixtures.epoch,
            attachments: [],
            signature: signature,
            content: DraftInput(
                mailboxID: "mbx_support",
                from: "support@example.com",
                to: ["ada@example.net"],
                subject: "Hello",
                text: "Hi"
            )
        )
    }

    /// A fresh composer asks for the sending address's signatures and shows the
    /// automatic default. Fails if the request is skipped or the wrong signature
    /// is presented as the one that will go out.
    @Test func newComposeDefaultsToTheAutomaticSignature() async {
        let outbox = FakeOutbox()
        await outbox.setSignatures(Self.candidates)
        let model = Self.model(outbox)

        await model.loadSignatures()

        #expect(await outbox.signatureRequests == ["support@example.com"])
        #expect(model.draft.signature == .automatic)
        #expect(model.signatureTag == "automatic")
        #expect(model.signaturePreview == "Support Team")
        #expect(model.showsSignaturePicker)
    }

    /// The picker names the default and always offers a way out of it.
    @Test func pickerListsEveryCandidateAndNoSignature() async {
        let outbox = FakeOutbox()
        await outbox.setSignatures(Self.candidates)
        let model = Self.model(outbox)

        await model.loadSignatures()

        #expect(model.signatureOptions.map(\.id) == [
            "automatic", "selected:sig_mailbox", "selected:sig_personal", "none",
        ])
        #expect(model.signatureOptions[0].label == "Default · Support")
        #expect(model.signatureOptions[1].label == "Support · support@example.com")
        #expect(model.signatureOptions[2].label == "Ada · Personal")
        #expect(model.signatureOptions.filter { !$0.isSelectable }.isEmpty)
        #expect(model.signatureMenuLabel == "Default · Support")
    }

    /// Switching has to change the SELECTION (what the send carries), not just
    /// the preview, and has to dirty the draft so the autosave persists it —
    /// a send that names a draft uses the draft's stored snapshot.
    @Test func switchingSignatureUpdatesSelectionAndDirtiesTheDraft() async {
        let outbox = FakeOutbox()
        await outbox.setSignatures(Self.candidates)
        let model = Self.model(outbox)
        await model.loadSignatures()

        model.signatureTag = "selected:sig_personal"

        #expect(model.draft.signature == .selected(id: "sig_personal"))
        #expect(model.signaturePreview == "Ada Lovelace")
        #expect(model.draft.isDirty)
    }

    /// "No signature" must silence the preview as well as the selection.
    @Test func choosingNoSignatureClearsThePreview() async {
        let outbox = FakeOutbox()
        await outbox.setSignatures(Self.candidates)
        let model = Self.model(outbox)
        await model.loadSignatures()

        model.signatureTag = "none"

        #expect(model.draft.signature == .noSignature)
        #expect(model.signaturePreview == nil)
    }

    /// Picking the explicit "Default" row goes back to following the address's
    /// default, rather than pinning today's default as a specific signature.
    @Test func choosingDefaultRestoresTheAutomaticSelection() async {
        let outbox = FakeOutbox()
        await outbox.setSignatures(Self.candidates)
        let model = Self.model(outbox)
        await model.loadSignatures()
        model.signatureTag = "selected:sig_personal"

        model.signatureTag = "automatic"

        #expect(model.draft.signature == .automatic)
        #expect(model.signaturePreview == "Support Team")
    }

    /// Reopening a draft that was saved with "No signature" must not put the
    /// default back — the stored snapshot is the user's decision.
    @Test func reopenedNoSignatureDraftStaysWithout() async {
        let outbox = FakeOutbox()
        await outbox.setSignatures(Self.candidates)
        let model = Self.model(outbox, kind: .draft, storedDraft: Self.storedDraft(.empty))

        await model.loadSignatures()

        #expect(model.draft.signature == .noSignature)
        #expect(model.signatureTag == "none")
        #expect(model.signaturePreview == nil)
        #expect(model.draft.isDirty == false)
    }

    /// A draft whose signature has since been deleted still shows what it will
    /// send — as an unselectable "saved copy" row, because re-selecting that id
    /// would be a 400 `SIGNATURE_NOT_AVAILABLE`.
    @Test func aDeletedSignatureStillShowsItsSavedCopy() async throws {
        let outbox = FakeOutbox()
        await outbox.setSignatures(SignatureCandidates(
            automaticSignatureID: nil, signatures: [Self.personalSignature]
        ))
        let snapshot = SignatureSnapshot(
            mode: .selected, id: "sig_gone", name: "Old", html: "<p>Old</p>", text: "Old sign-off"
        )
        let model = Self.model(outbox, kind: .draft, storedDraft: Self.storedDraft(snapshot))

        await model.loadSignatures()

        #expect(model.signaturePreview == "Old sign-off")
        let saved = try #require(model.signatureOptions.first { $0.id == "selected:sig_gone" })
        #expect(saved.label == "Old · Saved copy (unavailable)")
        #expect(saved.isSelectable == false)
        // Choosing it is a no-op rather than a request the server would reject.
        model.signatureTag = "selected:sig_gone"
        #expect(model.draft.signature == .selected(id: "sig_gone"))
        #expect(model.draft.isDirty == false)
    }

    /// A server older than 1.3.4 has no signatures route. The composer must still
    /// work — it just has no picker.
    @Test func aServerWithoutSignaturesHidesThePicker() async {
        let outbox = FakeOutbox()
        await outbox.setSignatures(nil)
        let model = Self.model(outbox)

        await model.loadSignatures()

        #expect(model.showsSignaturePicker == false)
        #expect(model.signatureOptions.map(\.id) == ["automatic", "none"])
        #expect(model.signaturePreview == nil)
    }

    /// The invariant this whole feature can silently break: the signature is the
    /// SERVER's to append, so nothing may put it in the body the user authored.
    @Test func theSignatureNeverEntersTheAuthoredBody() async {
        let outbox = FakeOutbox()
        await outbox.setSignatures(Self.candidates)
        let model = Self.model(outbox)
        await model.loadSignatures()
        model.toText = "ada@example.net"
        model.subject = "Hello"
        model.bodyText = "Hi"

        _ = await model.send()

        let sent = await outbox.lastSent
        #expect(sent?.body == "Hi")
        #expect(sent?.signature == .automatic)
    }
}
