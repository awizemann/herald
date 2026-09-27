import XCTest

/// U3 — a session that dies under the user, and the ways back in. Automates
/// checks 1–4 of `documents/reports/session-recovery-manual-checklist-2026-09-26.md`.
///
/// GOTCHA every test here respects: with the app frontmost and the presenter
/// on `succeed`, Herald's AUTOMATIC re-auth repairs a dead session silently
/// and the banner never shows. So each test picks a presenter that leaves the
/// state it wants on screen — `userCancel` (the automatic attempt ends at once,
/// Sign In offered) or `hangUntilCancelled` (the attempt stays running, Cancel
/// offered) — and switches to `succeed` only when it WANTS the repair.
@MainActor
final class DeadSessionRecoveryTests: HeraldUITestCase {
    /// Well under the 15 s active sync poll: something appearing inside this
    /// was caused by the test's own action, not by the next poll.
    static let prompt: TimeInterval = 5

    /// Checklist 1. Catches: a Send that 401s without raising the banner until
    /// the next sync poll (P2 routing); a compose error that is text only, with
    /// no Sign In (P4); a refresh storm on the dead grant (P1 latch — the
    /// incident did six in 65 s); typing that clears the sticky error or
    /// restarts autosave into the dead session.
    func testSendIntoADeadSessionRaisesTheBannerAndComposeSignInAtOnce() throws {
        launch(.oneAccount, presenter: .userCancel)
        let compose = openFilledComposer()
        controls.resetCounters()
        killSession()

        compose.clickSend()

        XCTAssertTrue(
            banner.container.waitUntilExists(timeout: Self.prompt),
            "the re-auth banner did not come up within \(Self.prompt)s of a Send that 401'd"
        )
        XCTAssertTrue(compose.waitForSignInOffered(), "the compose error bar offers no Sign In")
        XCTAssertTrue(banner.waitForSignInOffered(), "the banner offers no Sign In after the automatic attempt ended")

        let afterSend = try XCTUnwrap(controls.waitForStatus { ($0.sendRequests ?? 0) >= 1 })
        XCTAssertEqual(afterSend.sends, 0, "a send was accepted by a dead session")
        XCTAssertTrue(
            Wait.holds(for: Self.prompt) { (controls.currentStatus()?.refreshes ?? 0) <= 2 },
            "refresh storm on a dead grant: \(controls.currentStatus()?.description ?? "no status")"
        )

        // Typing must neither clear the error nor autosave into the dead grant.
        let beforeTyping = try XCTUnwrap(controls.waitForStatus())
        compose.body.clickAndType(" More text after the failure.")
        XCTAssertTrue(
            // Longer than the 2 s autosave debounce.
            Wait.holds(for: 4) { compose.errorMessage.exists && compose.errorSignIn.exists },
            "typing cleared the dead-session error"
        )
        let afterTyping = try XCTUnwrap(controls.waitForStatus())
        XCTAssertEqual(afterTyping.draftUpdates, beforeTyping.draftUpdates, "typing autosaved into a dead session")
        XCTAssertEqual(afterTyping.draftCreates, beforeTyping.draftCreates, "typing autosaved into a dead session")
        XCTAssertEqual(afterTyping.unauthorized, beforeTyping.unauthorized, "typing caused more 401s")
    }

    /// Checklist 2. Catches: an automatic attempt with no Cancel (the spinner
    /// was the end of the road until the 10-minute watchdog); a Cancel that
    /// does not give Sign In back at once; a Sign In pressed right after Cancel
    /// that the stale attempt steals or undoes.
    func testCancellingTheAutomaticAttemptGivesSignInBackAtOnce() throws {
        launch(.oneAccount, presenter: .hangUntilCancelled)
        killSessionAndWaitForBanner()

        XCTAssertTrue(banner.waitForAttemptRunning(), "no automatic attempt (no Cancel) with Herald frontmost")
        XCTAssertNotNil(controls.waitForStatus { $0.pendingSignIns == 1 }, "the automatic attempt is not parked")
        // The parked window stays parked; only the NEXT sign-in succeeds.
        controls.setPresenter(.succeed)

        banner.cancel.waitAndClick()

        XCTAssertTrue(banner.waitForSignInOffered(timeout: 3), "Cancel did not give Sign In back at once")
        XCTAssertNotNil(
            controls.waitForStatus(timeout: 3) { $0.pendingSignIns == 0 },
            "Cancel left the sign-in window open"
        )

        // Right after Cancel, no pause.
        banner.signIn.click()

        XCTAssertTrue(banner.waitUntilGone(), "Sign In right after Cancel did not sign the account in")
        let signedIn = try XCTUnwrap(controls.waitForStatus())
        XCTAssertEqual(signedIn.signIns, 2, "expected the cancelled automatic attempt plus the user's")
        XCTAssertTrue(
            Wait.holds(for: 3) { !banner.container.exists },
            "the banner came back: the stale attempt undid the sign-in"
        )

        // Healthy for real: a refresh goes through on the new grant.
        controls.resetCounters()
        refreshMail()
        XCTAssertTrue(
            Wait.holds(for: 3) { (controls.currentStatus()?.unauthorized ?? 0) == 0 && !banner.container.exists },
            "the refreshed account is still rejected"
        )
        XCTAssertTrue(mailList.waitForRow(subject: SmokeTests.seededSubjects[0]), "the inbox is gone after re-auth")
    }

    /// Checklist 3. Catches: a sidebar "Sign in again" that is plain text (or
    /// a button that does nothing); one left enabled while an attempt runs
    /// (a second click would open a second consent window over the first);
    /// a status slot that stays on "Sign in again" after a successful sign-in.
    func testSidebarSignInAgainSignsInAndIsDisabledDuringAnAttempt() {
        launch(.oneAccount, presenter: .userCancel)
        killSessionAndWaitForBanner()

        XCTAssertTrue(sidebar.waitForSignInAgainEnabled(), "the sidebar offers no clickable Sign in again")

        // While an attempt runs it is shown but disabled.
        controls.setPresenter(.hangUntilCancelled)
        sidebar.statusSignIn.click()
        XCTAssertTrue(banner.waitForAttemptRunning(), "the sidebar's Sign in again started no attempt")
        XCTAssertTrue(
            Wait.until { sidebar.statusSignIn.exists && !sidebar.statusSignIn.isEnabled },
            "Sign in again stayed enabled while an attempt was running"
        )
        banner.cancel.waitAndClick()
        XCTAssertTrue(sidebar.waitForSignInAgainEnabled(), "Sign in again did not come back after Cancel")

        // And with a working sign-in window it signs the account in.
        controls.setPresenter(.succeed)
        sidebar.statusSignIn.waitAndClick()

        XCTAssertTrue(banner.waitUntilGone(), "the sidebar's Sign in again did not sign the account in")
        XCTAssertTrue(sidebar.statusSignIn.waitUntilGone(), "the status slot still offers Sign in again")
        XCTAssertTrue(sidebar.status.exists, "the status slot is gone")
    }

    /// Checklist 4. Catches: a compose window closed or emptied by the
    /// re-auth's re-install; an error bar that stays after signing in; a
    /// message sent automatically on sign-in; a Send (double-clicked) that
    /// goes out twice.
    func testComposerKeepsItsTextAcrossSignInAndSendsExactlyOnce() throws {
        launch(.oneAccount, presenter: .userCancel)
        let compose = openFilledComposer()
        killSession()
        compose.clickSend()
        XCTAssertTrue(compose.waitForSignInOffered(), "no compose Sign In after a Send into a dead session")
        let before = composerText(compose)

        controls.setPresenter(.succeed)
        compose.errorSignIn.waitAndClick()

        XCTAssertTrue(compose.errorMessage.waitUntilGone(), "the compose error stayed after signing in")
        XCTAssertTrue(banner.waitUntilGone(), "the banner stayed after the composer's Sign In")
        let after = composerText(compose)
        XCTAssertEqual(after.to, before.to, "recipients changed across sign-in")
        XCTAssertEqual(after.subject, Draft.subject, "the subject changed across sign-in")
        XCTAssertTrue(after.body.contains(Draft.body), "the body lost its text across sign-in: \"\(after.body)\"")
        XCTAssertTrue(
            Wait.holds(for: 3) { controls.currentStatus()?.sends == 0 },
            "the message was sent automatically on sign-in"
        )

        controls.resetCounters()
        compose.send.waitUntilEnabled()
        compose.send.doubleClick()

        XCTAssertNotNil(controls.waitForCount("sends", atLeast: 1), "Send after sign-in sent nothing")
        XCTAssertTrue(
            Wait.holds(for: 4) {
                let status = controls.currentStatus()
                return status?.sends == 1 && status?.sendRequests == 1
            },
            "a double-clicked Send went out more than once: \(controls.currentStatus()?.description ?? "no status")"
        )
        XCTAssertTrue(compose.send.waitUntilGone(), "the compose window stayed open after a successful send")
    }
}
