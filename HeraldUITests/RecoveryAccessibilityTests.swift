import XCTest

/// U4 scenario 9 (checklist 5, VoiceOver): every control the recovery
/// scenarios press exists with a non-empty accessibility LABEL, and the ones
/// the checklist names read exactly as it says. Announcements themselves are
/// not observable from XCUITest; the unit tests pin their wording.
@MainActor
final class RecoveryAccessibilityTests: HeraldUITestCase {
    /// Catches: an unlabelled (or icon-named) control on the recovery path —
    /// VoiceOver would read "button" — and the checklist's names drifting
    /// ("Cancel sign-in", "Sign in again", "Signing in to this message’s account").
    func testRecoveryControlsHaveLabels() {
        launch(.oneAccount, presenter: .hangUntilCancelled)
        assertLabeled(mailList.composeButton, "toolbar New Message")
        assertLabeled(mailList.refreshButton, "toolbar Refresh")

        let compose = openFilledComposer()
        assertLabeled(compose.to, "compose To", equals: "To")
        assertLabeled(compose.subject, "compose Subject", equals: "Subject")
        assertLabeled(compose.body, "compose body", equals: "Message body")
        assertLabeled(compose.send, "compose Send", equals: "Send")

        // An attempt running: banner Cancel, compose "Signing in…", sidebar disabled.
        killSession()
        compose.clickSend()
        XCTAssertTrue(banner.waitForAttemptRunning(), "no automatic attempt to inspect")
        assertLabeled(banner.message, "banner message")
        assertLabeled(banner.cancel, "banner Cancel", equals: "Cancel sign-in")
        XCTAssertTrue(compose.errorSigningIn.waitUntilExists(), "compose shows no sign-in progress")
        assertLabeled(compose.errorSigningIn, "compose signing-in", equals: "Signing in to this message’s account")
        assertLabeled(compose.errorMessage, "compose error message")
        XCTAssertTrue(sidebar.statusSignIn.waitUntilExists(), "the sidebar offers no Sign in again")
        assertLabeled(sidebar.statusSignIn, "sidebar Sign in again", equals: "Sign in again")

        // Sign In offered everywhere.
        banner.cancel.click()
        XCTAssertTrue(banner.waitForSignInOffered(), "Cancel did not bring Sign In back")
        assertLabeled(banner.signIn, "banner Sign In", equals: "Sign In")
        XCTAssertTrue(compose.waitForSignInOffered(), "compose Sign In did not come back")
        assertLabeled(compose.errorSignIn, "compose Sign In", equals: "Sign In")
        XCTAssertTrue(sidebar.waitForSignInAgainEnabled(), "sidebar Sign in again did not re-enable")
        assertLabeled(sidebar.statusSignIn, "sidebar Sign in again (enabled)", equals: "Sign in again")

        // The Add Account sheet.
        assertLabeled(sidebar.accountOptions, "sidebar account options")
        sidebar.addAccount()
        XCTAssertTrue(onboarding.waitUntilVisible(), "Add Account opened no sheet")
        assertLabeled(onboarding.origin, "onboarding server address", equals: "Server address")
        assertLabeled(onboarding.signIn, "onboarding Sign In", equals: "Sign In")
        assertLabeled(onboarding.cancel, "onboarding Cancel", equals: "Cancel")
        onboarding.cancel.click()
        XCTAssertTrue(onboarding.origin.waitUntilGone(), "the sheet's Cancel did not close it")
    }

    /// Exists, has a non-empty label, and (when given) exactly `expected`.
    private func assertLabeled(
        _ element: XCUIElement,
        _ name: String,
        equals expected: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard element.waitUntilExists() else {
            XCTFail("\(name) does not exist", file: file, line: line)
            return
        }
        // A StaticText's spoken words are its AX VALUE (label empty) — that is
        // what VoiceOver reads for the combined banner/compose messages. Any
        // other element type must carry a real label.
        let spoken = element.elementType == .staticText ? element.text : element.label
        let label = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(label.isEmpty, "\(name) has no accessibility label", file: file, line: line)
        if let expected {
            XCTAssertEqual(label, expected, "\(name) is read as \"\(label)\"", file: file, line: line)
        }
    }
}
