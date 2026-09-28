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
    @Test func saveCaptionOnlyClaimsSavedWhenTheServerHasEverything() {
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: FakeOutbox()
        )
        #expect(model.saveStatusCaption == nil, "a never-saved message claimed to be saved")
        model.subject = "Lunch"
        #expect(model.saveStatusCaption == nil, "unsaved edits claimed to be saved")
    }
}
