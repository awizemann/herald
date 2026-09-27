# Session recovery: manual checklist v2 (manual-only remainder)

Written 2026-09-27 (UI-test plan `documents/plans/ui-tests-2026-09-27.md`, phase U5). It replaces the checks in `reports/session-recovery-manual-checklist-2026-09-26.md` (v1) that the XCUITest suite now automates. v1 stays for its reference material: the kill-the-session table and the server-version notes.

**What the automation cannot reach:** the UI tests run the Debug app in `-HeraldUITest` mode. That mode uses an in-process fake HQBase, a scripted sign-in presenter and an in-memory account store. It never uses the network, the real `ASWebAuthenticationSession` window, the real Keychain or LaunchServices. Everything below depends on one of those. Run the automated suite first with `scripts/ui-tests.sh` (about 9 minutes; it takes over the screen).

## Before you start

- **Use the release build** (`/Applications/Herald.app`) for items M4 and M5. Use the dev copy for the rest. Both copies claim the `com.wizemann.herald:` callback scheme, so quit the one you are not testing.
- Herald accepts **https servers only**. The local wrangler instances are `http://localhost` and cannot be used without an https front.
- Use v1's "How to kill the session" table to pick the kill method for the server version under test.
- Keep a log stream open: `log stream --predicate 'subsystem == "com.wizemann.herald" AND process == "Herald"' --level info`

## Manual-only checks

### M1. Real sign-in window (ASWebAuthenticationSession)
- [ ] The automatic re-auth (Herald frontmost at the moment of expiry) opens the **real** web sheet. Cancel in the banner closes that sheet, not only Herald's state.
- [ ] The Cancel/close button of the web sheet itself ends the attempt. The banner offers Sign In at once, without waiting for the 10-minute watchdog.
- [ ] Completing web consent from the **compose** Sign In and from the **banner** Sign In both return to Herald. The error clears, and the composer keeps its text.
- Automated around it: `DeadSessionRecoveryTests/testCancellingTheAutomaticAttemptGivesSignInBackAtOnce` (scripted presenter), `DeadSessionRecoveryTests/testComposerKeepsItsTextAcrossSignInAndSendsExactlyOnce`, and the unit test "cancelling the awaiting task tears the browser session down".

### M2. Real https HQBase, 1.4.0 and 1.4.2
- [ ] **1.4.0** (web sign-out): the banner appears on Send right away, and the log shows **at most one** refresh and then "grant latched". There is no refresh storm.
- [ ] **1.4.2** (web sign-out): silent recovery with no banner. On 1.4.2, sign-out is not a way to kill the session.
- [ ] **1.4.2** (revoke the grant, which gives `invalid_grant`): the Keychain item is cleared, then the banner appears and Sign In recovers.
- [ ] After a re-auth, a Send arrives **exactly once** on the real server (the idempotency key is kept), and autosave updates the draft on the web.
- Automated around it (fake server states `deadSession140`, `invalidGrant`, `bareTokenEndpoint401`, `invalidClient`): `DeadSessionRecoveryTests/testSendIntoADeadSessionRaisesTheBannerAndComposeSignInAtOnce`, `…/testComposerKeepsItsTextAcrossSignInAndSendsExactlyOnce`, and the HeraldKit latch suites ("refresh-OK-then-401 latches the grant…", "invalid_grant clears the item, never latches, and announces exactly once").

### M3. VoiceOver spoken announcements (Cmd-F5)
- [ ] When the banner appears, VoiceOver says "Your session expired. Use the Sign In button in the banner to keep syncing." During an automatic attempt it says "…Signing you back in… Use the Cancel button in the banner to stop."
- [ ] After a Cancel it says "Sign-in cancelled. Use the Sign In button in the banner when you're ready."
- [ ] After the composer's re-auth it says "Signed in again. Press Send to send your message."
- [ ] The banner icon is not read aloud, and every control is reachable with VO navigation and with the keyboard alone.
- Automated around it: `RecoveryAccessibilityTests/testRecoveryControlsHaveLabels` checks the labels ("Cancel sign-in", "Sign in again", compose "Signing in to this message's account"). Only the spoken output and real VO focus movement remain manual.

### M4. Callback scheme and LaunchServices (release app)
- [ ] With **only** the release app running, sign-in returns to the release app. With the dev copy also running, note which copy receives the callback. A callback that goes to the wrong copy must fail cleanly (state mismatch), never sign the wrong copy in.
- Automated around it: the unit tests "a callback with a mismatched state aborts before the token endpoint" and "an unauthorized_client callback forgets the registration only when the state matches". There is no UI test: UI-test mode never leaves the process.

### M5. Relaunch after Cancel and after a latch (real Keychain)
- [ ] After Cancel during the automatic attempt, **quit and relaunch**. The account is still listed; a Cancel must not delete the Keychain account.
- [ ] While the session is still dead, relaunch once. Herald does exactly one refresh and then latches again (the latch is in memory only), with no storm.
- [ ] After production moves to 1.4.2, a relaunch alone recovers a grant latched under 1.4.0.
- Automated around it: the unit tests "cancelSignIn clears the state and a second attempt runs" and "a sign-in that completes after being cancelled does not install". UI-test mode's account store is in memory, so persistence across a relaunch can only be checked by hand.

### M6. macOS 26 layout of the re-auth banner fix (commit 7d53ef5)
- [ ] On macOS 26 (Tahoe), with the re-auth banner up, the banner sits **above** the split view. The sidebar header (Sign in again, account options) is visible and clickable, and the first mail row is not clipped. Also check at a narrow window width.
- Automated around it: `DeadSessionRecoveryTests/testSidebarSignInAgainSignsInAndIsDisabledDuringAnAttempt` asserts the sidebar's Sign in again is hittable with the banner up. It has only run on macOS 27.

### M7. Banner-up layout: content shifts down (full screen, sidebar collapsed, toolbar hidden)
Since commit 7d53ef5 the re-auth banner sits above the split view and pushes the whole window content down, instead of being laid over it (audit fresh-eyes F7). The UI tests run only in a normal-size window with the sidebar and toolbar shown.
- [ ] **Full screen** (Ctrl-Cmd-F): with the banner up, the banner sits below the menu bar or the toolbar and is not hidden behind them. The sidebar header and the first mail row are visible and not clipped. When the banner goes away (after Sign In), the content moves back up with no gap left behind.
- [ ] **Sidebar collapsed** (View > Hide Sidebar): the banner spans the window. Its Sign In and Cancel stay clickable, and the list's first row is not covered. Show the sidebar again while the banner is up: its header (Sign in again, account options) is visible and clickable.
- [ ] **Toolbar hidden** (View > Hide Toolbar): the banner sits directly under the title bar and is not clipped or overlapped by it. Showing the toolbar again with the banner up moves the content down cleanly.
- [ ] In each of the three states, raise and clear the banner twice. The layout comes back the same every time, with no leftover blank band and no content stuck behind the banner.
- Automated around it: `DeadSessionRecoveryTests/testSidebarSignInAgainSignsInAndIsDisabledDuringAnAttempt` asserts the sidebar's Sign in again is hittable with the banner up, in the default window only.

## Not automated yet (automatable, so candidates for UI tests)
These are v1 checks with no UI test yet. They do not need anything real, so they remain manual only until someone writes the test.
- [ ] v1 §3: a non-auth sync failure after the latch does not replace the sidebar's "Sign in again" state.
- [ ] v1 §4: composer **attachments** survive re-auth. Variant: re-auth from the **main banner** rebinds an open composer.
- [ ] v1 §4: sign the account **out** while a composer is open. Send is blocked with a reason, and the text stays.

## Map: v1 item → where it is covered now

| v1 item | Covered by |
|---|---|
| 1 Banner at once on Send; compose Sign In; no refresh storm; typing doesn't clear or autosave | `DeadSessionRecoveryTests/testSendIntoADeadSessionRaisesTheBannerAndComposeSignInAtOnce` (+ HeraldKit latch suites). Real-server check: M2 |
| 2 Cancel gives Sign In back at once; Sign In right after Cancel works | `DeadSessionRecoveryTests/testCancellingTheAutomaticAttemptGivesSignInBackAtOnce`. Real window: M1 |
| 2 Relaunch after Cancel keeps the account | **Manual**: M5 |
| 3 Sidebar Sign in again is a button, disabled during an attempt | `DeadSessionRecoveryTests/testSidebarSignInAgainSignsInAndIsDisabledDuringAnAttempt` |
| 3 Non-auth failure doesn't replace Sign in again | Not automated yet (see above) |
| 4 Composer keeps text, error clears, nothing auto-sends, sends exactly once | `DeadSessionRecoveryTests/testComposerKeepsItsTextAcrossSignInAndSendsExactlyOnce`. Real server: M2 |
| 4 Attachments, banner variant, sign-out while composing | Not automated yet (see above) |
| 5 Labels (Cancel sign-in, Sign in again, compose signing-in) | `RecoveryAccessibilityTests/testRecoveryControlsHaveLabels` |
| 5 Spoken announcements, decorative icon, VO/keyboard reachability | **Manual**: M3 |
| (new, audit F7) Banner-up layout in full screen, sidebar collapsed, toolbar hidden | **Manual**: M7 |
| 6 Relaunch after latch; 1.4.2 recovery by relaunch | **Manual**: M5 (+ unit latch suites) |
| Failure reason in banner and composer (W5) | `SignInFailureTests/testAFailedSignInShowsItsReasonInTheBannerAndTheComposer` |
| Add Account activation failure (P9b G) | `SignInFailureTests/testAddAccountActivationFailureKeepsTheSheetOpenWithTheReason` |
| Sign-out failure alert (N4) | `SignInFailureTests/testASignOutThatCannotFinishRaisesAnAlertWithTheReason` |
| Add Account for an already signed-in server (W1) | `SignInFailureTests/testAddAccountForAnAlreadySignedInServerIsRefusedInline` |
