import Foundation
import HeraldKit
import Testing
@testable import Herald

/// The V6 compose window's derived strings: what VoiceOver says for a token,
/// and when the band claims the draft is saved.
@MainActor
struct ComposeWindowPresentationTests {
    /// Fails if a token drops its address when a name is known, loses the
    /// "invalid" cue (the danger colour is otherwise the only signal), or
    /// says "invalid" for a good address.
    @Test func tokenAccessibilityLabelNamesAddressAndValidity() {
        let named = RecipientToken(index: 0, address: "sales@acme.co", displayName: "Acme Sales", isValid: true)
        let bare = RecipientToken(index: 1, address: "erik@halvorsen", displayName: nil, isValid: false)
        #expect(RecipientTokenChip.accessibilityLabel(for: named) == "Recipient, Acme Sales, sales@acme.co")
        #expect(RecipientTokenChip.accessibilityLabel(for: bare) == "Recipient, erik@halvorsen, invalid")
    }

    /// "Draft saved" must never show for a message the server has never
    /// seen, nor while edits are waiting for the next autosave.
    @Test func saveCaptionOnlyClaimsSavedWhenTheServerHasEverything() async {
        let outbox = FakeOutbox()
        // The server answers with a stored draft, as the real one does.
        await outbox.setNormalizer { sent in
            ComposeDraft(
                id: sent.id, mode: sent.mode, mailboxID: sent.mailboxID, fromAddress: sent.fromAddress,
                to: sent.to, cc: sent.cc, bcc: sent.bcc, subject: sent.subject, body: sent.body,
                signature: sent.signature, sendAttemptKey: sent.sendAttemptKey,
                serverDraft: Draft(
                    id: "draft-1", version: 1, updatedAt: MailFixtures.epoch, attachments: [],
                    content: DraftInput(mailboxID: "mbA", from: sent.fromAddress, to: sent.to, subject: sent.subject, text: sent.body)
                ),
                isDirty: false
            )
        }
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: outbox,
            autosaveDelay: .seconds(3600)
        )
        #expect(model.saveStatusCaption == nil, "a never-saved message claimed to be saved")
        model.subject = "Lunch"
        #expect(model.saveStatusCaption == nil, "unsaved edits claimed to be saved")

        await model.saveNow()
        #expect(model.saveStatusCaption == "Draft saved", "a draft the server holds in full must say so")

        model.subject = "Lunch?"
        #expect(model.saveStatusCaption == nil, "an edit after the save un-claims it")
    }
}
