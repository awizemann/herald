import XCTest

/// U4 — sign-in failures, the Add Account guard, and a sign-out that cannot
/// finish: each must SAY what happened where the user is looking (audit W5,
/// P9b items G/N4, audit W1).
@MainActor
final class SignInFailureTests: HeraldUITestCase {
    /// Distinctive, so a label containing it can only have come from the
    /// scripted window's failure.
    static let failureReason = "UI-test consent page answered 500."

    /// Catches: a failed sign-in that only brings the Sign In button back,
    /// with no reason in the banner or in the compose error bar (audit W5).
    func testAFailedSignInShowsItsReasonInTheBannerAndTheComposer() throws {
        launch(.oneAccount, presenter: .fail(Self.failureReason))
        let compose = openFilledComposer()
        killSession()
        compose.clickSend()
        XCTAssertTrue(banner.waitForSignInOffered(), "no banner Sign In after a Send into a dead session")
        XCTAssertTrue(compose.waitForSignInOffered(), "no compose Sign In after a Send into a dead session")

        // The user's own attempt (whatever the automatic one did first).
        let attemptsBefore = try XCTUnwrap(controls.waitForStatus()?.signIns, "no parseable uitest.status")
        banner.signIn.click()

        XCTAssertNotNil(controls.waitForCount("signIns", atLeast: attemptsBefore + 1), "Sign In opened no sign-in window")
        XCTAssertTrue(
            banner.waitForMessage(containing: Self.failureReason),
            "the banner does not say why the sign-in failed: \"\(banner.messageText)\""
        )
        XCTAssertTrue(banner.signIn.exists, "the banner lost its Sign In after a failure")
        XCTAssertTrue(
            compose.waitForError(containing: Self.failureReason),
            "the compose error bar does not say why the sign-in failed: \"\(compose.errorMessage.text)\""
        )
        XCTAssertTrue(compose.errorSignIn.exists, "the compose bar lost its Sign In after a failure")

        // The composer's own Sign In fails the same way, and says so again.
        // (The banner click brought the main window forward over the composer.)
        compose.bringToFront()
        compose.errorSignIn.click()
        XCTAssertNotNil(controls.waitForCount("signIns", atLeast: attemptsBefore + 2), "compose Sign In opened no window")
        XCTAssertTrue(compose.waitForSignInOffered(), "compose Sign In never came back after the failure")
        XCTAssertTrue(compose.waitForError(containing: Self.failureReason), "the composer's own failure has no reason")
    }

    /// Catches (P9b item G): Add Account closing its sheet before the account
    /// is installed, so an activation failure after consent landed on a sheet
    /// that was already gone and nobody saw it.
    func testAddAccountActivationFailureKeepsTheSheetOpenWithTheReason() throws {
        launch(.oneAccount)
        XCTAssertTrue(mailList.waitForRow(subject: SmokeTests.seededSubjects[0]), "the inbox never loaded")
        controls.setActivationRefused(true)

        sidebar.addAccount()
        XCTAssertTrue(onboarding.waitUntilVisible(), "Add Account opened no sheet")
        onboarding.signIn(origin: OnboardingPage.secondaryOrigin)

        // `OAuthError.unknownAccount` — what activation without a cache fails with.
        XCTAssertTrue(
            onboarding.waitForError(containing: "no longer signed in"),
            "the activation failure is not on the sheet (error: \"\(onboarding.error.exists ? onboarding.error.text : "none")\")"
        )
        XCTAssertTrue(onboarding.origin.exists, "the Add Account sheet closed on an activation failure")
        XCTAssertTrue(onboarding.signIn.waitUntilEnabled(), "the sheet is stuck signing in after the failure")
        let status = try XCTUnwrap(controls.waitForStatus())
        XCTAssertEqual(status.signIns, 1, "the failure must come after consent (one sign-in window)")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(status.codeExchanges), 1, "consent never completed")
        XCTAssertFalse(sidebar.hasSeveralAccounts, "an account that failed to activate was added anyway")
    }

    /// Catches (audit N4): a sign-out whose Keychain half fails with other
    /// accounts left, saying nothing — the account then came back at the
    /// next launch, looking like Herald had ignored the sign-out.
    func testASignOutThatCannotFinishRaisesAnAlertWithTheReason() {
        launch(.twoAccounts)
        XCTAssertTrue(sidebar.waitForSeveralAccounts(), "two accounts signed in, but the app shows one")
        controls.setAccountStoreRefusesList(true)

        sidebar.signOut()

        XCTAssertTrue(
            alerts.waitForAlert(titled: AlertsPage.signOutFailedTitle),
            "no \"\(AlertsPage.signOutFailedTitle)\" alert"
        )
        XCTAssertTrue(
            alerts.text(containing: "couldn’t remove it from this Mac").waitUntilExists(),
            "the alert does not say what was left behind"
        )
        // `AccountStoreError.indexUnreadable`: the reason itself.
        XCTAssertTrue(
            alerts.text(containing: "can't read its saved list of accounts").waitUntilExists(),
            "the alert does not carry the reason"
        )

        alerts.signOutFailedOK.waitAndClick()

        XCTAssertTrue(
            app.staticTexts[AlertsPage.signOutFailedTitle].firstMatch.waitUntilGone(),
            "OK did not dismiss the alert"
        )
    }

    /// Catches (audit W1): Add Account for a server that is already signed in
    /// going ahead — a second sign-in to the same origin, possibly as another
    /// user, would replace the existing account's grant under the same id.
    /// It must be refused inline BEFORE any sign-in window opens.
    func testAddAccountForAnAlreadySignedInServerIsRefusedInline() {
        launch(.oneAccount)
        XCTAssertTrue(mailList.waitForRow(subject: SmokeTests.seededSubjects[0]), "the inbox never loaded")

        sidebar.addAccount()
        XCTAssertTrue(onboarding.waitUntilVisible(), "Add Account opened no sheet")
        onboarding.signIn(origin: OnboardingPage.primaryOrigin)

        XCTAssertTrue(
            onboarding.waitForError(containing: "already signed in to hqbase.uitest.invalid"),
            "no inline refusal (error: \"\(onboarding.error.exists ? onboarding.error.text : "none")\")"
        )
        XCTAssertTrue(onboarding.origin.exists, "the sheet closed on a refusal")
        XCTAssertTrue(
            Wait.holds(for: 3) {
                let status = controls.currentStatus()
                return status?.signIns == 0 && status?.registrations == 0 && status?.codeExchanges == 0
            },
            "a sign-in started for an already-signed-in server: \(controls.currentStatus()?.description ?? "no status")"
        )
    }
}
