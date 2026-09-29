---
title: Herald UI Testing
type: note
permalink: hqbase-mac/conventions/herald-ui-testing
tags: [testing, uitest, xcuitest]
source_paths: [Herald/UITestSupport, HeraldUITests, scripts/ui-tests.sh, scripts/verify-release-identity.sh, Herald/Support/AccessibilityID.swift, project.yml, HeraldTests/UITestHarnessTests.swift, HeraldTests/DebugIdentityTests.swift]
source_paths_inferred: false
source_sha: db538bd984d6059832d0ed07712103e28caf1685
created: 2026-09-27
updated: 2026-09-28
reviewed: 2026-09-28
reviewed_by: audit:claude-code (background)
---

Current-state knowledge of Herald's XCUITest suite (scheme `HeraldUITests`) and the Debug-only UI-test harness it drives. General unit-test rules: [[Herald Testing Conventions]]. Build/bundle-id facts: [[Herald Build and Toolchain]].

## Harness contract (Herald/UITestSupport, Debug only)
- Launch args (UITestLaunch.swift): `-HeraldUITest <signedOut|oneAccount|twoAccounts>`, optional `-HeraldUITestServer <healthy|deadSession140|invalidGrant|bareTokenEndpoint401|invalidClient>`, optional `-HeraldUITestPresenter <succeed|hangUntilCancelled|userCancel|fail|fail:<reason>>`. Missing/unknown value → `fatalError` ("UI-test launch refused"). Only the first occurrence of each flag is read.
- Scenarios: both fake origins (`https://hqbase.uitest.invalid`, `https://second.uitest.invalid`; `.invalid` never resolves) are served in EVERY scenario; `signedOut` seeds none, `oneAccount` the primary (5 Inbox messages; the secondary is Add Account's target), `twoAccounts` both.
- Composition root (`UITestHarness`): `InMemoryAccountStore`, `ScriptedSignInPresenter`, `FakeHQBase` per origin behind `FakeHQBaseProtocol` on the harness `URLSession` only (request timeout 15 s, resource 30 s), `/events` refused 503 (`FakeEventChannels`), in-memory SwiftData, defaults suite `com.wizemann.herald.uitest` wiped at launch, `SilentNotificationPoster`, `NoopUsageTracker`, Sparkle not started, notification-click routing off. The harness also registers `ApplePersistenceIgnoreState=YES`/`NSQuitAlwaysKeepsWindows=NO` in the volatile registration domain.
- Server states apply to grants existing WHEN SET; a fresh sign-in mints a LIVE grant (that is how recovery is tested). `healthy` revives every grant except client-revoked ones and family-invalidated refresh tokens. `deadSession140` = Mail API 401 while refresh keeps rotating 200; `invalidGrant` = refresh 400 invalid_grant; `bareTokenEndpoint401` = refresh answers bare HTML 401; `invalidClient` = refresh AND code exchange 400 invalid_client, a new registration works.
- Presenter modes: `succeed`, `hangUntilCancelled` (parks until Cancel or complete-pending), `userCancel` (ends at once, no reason), `fail[:reason]`. `setPresenter(.succeed)` does NOT release an already parked attempt — use Cancel or `completePendingSignIns`.

## Control surface ("UI Test Controls" CommandMenu, UITestControls.swift)
- Items (identifier / title): `uitest.server.<state>` "Server: <state>"; `uitest.poll.pause|resume` "Sync poll: pause|resume"; `uitest.presenter.<succeed|hangUntilCancelled|fail|userCancel>` "Sign-in: <mode>"; `uitest.presenter.completePending` "Sign-in: complete pending"; `uitest.store.refuseList|healthy`; `uitest.activation.refuse|healthy`; `uitest.resetCounters` "Reset counters". The `uitest.` prefix is reserved for harness controls.
- Poll pause (`setSyncPollPaused`): the fakes HOLD every Mail API `GET /api/v1/…` unanswered and unseen (`FakeHQBase.holdReads/releaseReads`); writes (send, autosave PATCH) and the token endpoint still work; resume answers held reads as the server stands then. Use it whenever a test must prove ITS action (not a 15 s poll) met a server state. Held reads hit the 15 s request timeout — fine for "paused until the end of the test".
- Activation refused: holds the mail cache aside (`environment.store = nil`, as SessionRecoveryP9bTests does) so Add Account fails after consent with `OAuthError.unknownAccount`; running accounts are untouched.
- `FakeHQBase.holdRefreshResponses/releaseRefreshResponses` (unit-test only, no menu item): a refresh is answered (rotated) at once but delivered on release, back on the URLProtocol loading run loop (`CFRunLoopPerformBlock`, never blocking the shared protocol thread) — used to land a sign-in while a refresh is in flight.

## Status line (`uitest.status`)
- A plain `Text` (StaticText, words are its VALUE); wrapping it in `.accessibilityElement(children: .ignore)` made the value read back empty. Keys in fixed order, only ever appended: `server presenter sends sendRequests tokenRequests refreshes codeExchanges registrations signIns pendingSignIns draftCreates draftUpdates draftDeletes unauthorized revocations storeRefusesList activationRefused apiSuccesses pollPaused heldReads saveAttempts`.
- `UITestStatus.requiredKeys` = all of those except `activationRefused`; a status missing a required key never parses and every wait FAILS.
- Semantics: `sends` = DISTINCT accepted messages (idempotent replay not counted) → "sent exactly once" also asserts `sendRequests`; `apiSuccesses` = Mail API 2xx; `saveAttempts` = draft saves any composer ATTEMPTED (`ComposeViewModel(saveAttempted:)` → `AppEnvironment.composeSaveAttempted`), including ones a latched grant fails fast before reaching the server; `unauthorized` = 401s served. Server-only counters (not on the line): `refreshReplays`, `familyInvalidations`.

## Isolation guarantees
- Debug (so the unit-test host and UI-test target app) is bundle id `com.wizemann.herald.debug`: own container, prefs, Keychain namespace `.dev`, callback scheme. `XCUIApplication.launch()` kills same-id instances, so a UI run quits a running dev copy but can never touch the release app. Pinned by `DebugIdentityTests`.
- `scripts/ui-tests.sh [-only-testing:HeraldUITests/<Class>[/<test>]]`: refuses `-configuration -scheme -project -workspace -derivedDataPath -xctestrun -xcconfig` (and `=` forms) and any `NAME=value` arg (exit 2); exits 3 if the screen is locked (`ioreg … CGSSessionScreenIsLocked`); regenerates the project if stale; `build-for-testing` into `DerivedData-UITests/`; exit 4 unless the built app is `com.wizemann.herald.debug`; then `test-without-building -test-timeouts-enabled YES "$@"`. Log + .xcresult in `DerivedData/ui-tests-logs/`.
- `HeraldApp.launch` (HeraldUITests/Support/HeraldLaunch.swift) is the only place an `XCUIApplication` is built: always passes `-HeraldUITest` + `-ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO`, then `launch()` + `activate()` and requires `uitest.status` within `launchTimeout` (20 s) or terminates the app and fails. Never bypass it with a raw `XCUIApplication().launch()`.
- `scripts/verify-release-identity.sh <app>` (called by release.sh): Release id exactly `com.wizemann.herald`, one URL type/scheme = the release id, and no `HeraldUITest`, `uitest.`, `UITestHarness`, `FakeHQBase`, `com.wizemann.herald.debug`, `com.wizemann.herald.dev` strings anywhere in Contents/MacOS.
- The `Herald` scheme does NOT include HeraldUITests (project.yml) — keep it that way so `-scheme Herald test` stays fast and never takes over the screen. HeraldUITests target sets `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`; test classes and page objects are explicitly `@MainActor`.

## Identifiers
- ONE file, `Herald/Support/AccessibilityID.swift` (Foundation-only `nonisolated enum AccessibilityID`), compiled into BOTH the app and HeraldUITests via project.yml sources (the UI bundle cannot import the app). Scheme `<surface>.<part>[.<control>]`: `banner.reauth[.message|.signIn|.cancel]`, `banner.syncFailed[.message|.retry]`, `sidebar.status[.signIn]`, `sidebar.accountName|accountOptions[.addAccount|.signOut]|accountSwitcher|mailboxPicker`, `mailList`, `mailList.row.<threadID>`, `toolbar.compose|refresh`, `compose.to|cc|bcc|subject|body|send|attach|deleteDraft|busy|error.message|error.signIn|error.signingIn`, `onboarding.origin|signIn|cancel|error|progress`, `alert.signOutFailed.ok|actionError.ok`.
- Identifiers ONLY — never add/alter labels, hints, values or `.accessibilityElement` grouping to make a test easier.

## Page objects and waiting (HeraldUITests/)
- Tests subclass `@MainActor HeraldUITestCase` (continueAfterFailure=false, `executionTimeAllowance = 180` — enforced only via `-test-timeouts-enabled YES`; tearDown ALWAYS terminates), call `launch(.oneAccount, server:, presenter:)`, and use `banner`, `sidebar`, `mailList`, `compose`, `onboarding`, `alerts`, `controls` page structs. Query by identifier across all element types (`element(id:)`).
- Waiting (Support/Waiting.swift): `Wait.until` / `Wait.value` / `Wait.holds(for:)` (a condition STAYS true — the "nothing else happens" assertion), `waitUntilExists|Gone|Enabled|Hittable`, `waitForLabel|Value|Text`; poll 0.2 s, return Bool — assert on it; never `sleep`. Read message text with `XCUIElement.text` (label-else-value).
- Harness state: `controls.waitForStatus { … }`, `waitForCount(key, atLeast:)` (nil counter → `.min`, fails), `setServer/setPresenter/setSyncPollPaused/completePendingSignIns/setActivationRefused/setAccountStoreRefusesList/resetCounters` click the menu item by identifier-else-title and wait for the status to reflect it.
- Shared flows (Support/SessionFlows.swift): `openFilledComposer` waits for autosave QUIET (`waitForAutosaveQuiet`: draftCreates/draftUpdates/saveAttempts unchanged for `autosaveQuietPeriod` = 3 s > the 2 s debounce, no `compose.busy`) before any kill; `killSession`, `refreshMail`, `killSessionAndWaitForBanner`, `composerText`.
- Sidebar popups are queried INSIDE their button (`accountOptions.descendants(matching: .menuItem)`, same for `accountSwitcher`) — the menu bar has its own "Add Account…"/"Sign Out". Mail rows: `identifier BEGINSWITH "mailList.row." AND label CONTAINS "<subject>"`.

## Scenario coverage (checklist → test)
- 1 Send into a dead session → `DeadSessionRecoveryTests/testSendIntoADeadSessionRaisesTheBannerAndComposeSignInAtOnce` (poll paused first; banner absent before Send; `sendRequests == 2` = first try + AuthenticatingMiddleware's one post-refresh retry; `unauthorized == 2`; exactly one refresh; typing after the failure changes no `saveAttempts`).
- 2 Cancel during the automatic attempt → `…/testCancellingTheAutomaticAttemptGivesSignInBackAtOnce`; 3 Sidebar Sign in again → `…/testSidebarSignInAgainSignsInAndIsDisabledDuringAnAttempt` (also asserts the sidebar button is hittable with the banner up); 4 Composer survives re-auth, sends once → `…/testComposerKeepsItsTextAcrossSignInAndSendsExactlyOnce`.
- Failure reason (W5) → `SignInFailureTests/testAFailedSignInShowsItsReasonInTheBannerAndTheComposer`; Add Account activation failure (P9b G) → `…/testAddAccountActivationFailureKeepsTheSheetOpenWithTheReason`; sign-out failure alert (N4) → `…/testASignOutThatCannotFinishRaisesAnAlertWithTheReason`; Add Account for a signed-in server (W1) → `…/testAddAccountForAnAlreadySignedInServerIsRefusedInline`.
- 5 VoiceOver labels → `RecoveryAccessibilityTests/testRecoveryControlsHaveLabels`. Smoke: `SmokeTests` (seeded inbox, onboarding, controls + status reachable).
- Manual-only remainder: `documents/reports/session-recovery-manual-checklist-v2-2026-09-27.md` (real ASWebAuthenticationSession window, real HQBase 1.4.0/1.4.2 over https, VoiceOver speech, callback scheme + LaunchServices with the release app, relaunch persistence in the real Keychain, banner layout on macOS 26). Automatable but not yet automated: non-auth failure after the latch, attachments + banner-rebind variant, sign-out while composing.
- Harness unit tests: `HeraldTests/UITestHarnessTests.swift` — `UITestLaunchArgumentTests`, `UITestHarnessWiringTests` (e.g. `oneAccountServesAnUnseededSecondOrigin`, `activationRefusalFailsAddAccountAndRestores`, `pausingTheSyncPollHoldsReadsOnly`, `saveAttemptsFollowTheComposeHook`, `aSignInDuringAnInFlightDeadRefreshStaysHealthy`), `FakeHQBaseWireTests`, `ScriptedSignInPresenterTests`; plus `ComposeViewModelTests.everySaveThatReachesTheOutboxIsReportedAsAttempted`.

## Fake fidelity (FakeHQBase — follow [[HQBase Mail API v1 Contract]] exactly)
- Refresh binds the minted access token to the requested `resource`: missing/other → 200, but that token 401s on the Mail API (AUDIENCE-BOUND).
- A ROTATED refresh token replayed within `FakeHQBase.refreshTokenReuseInterval` (30 s, HQBase's value) gets that rotation's own tokens back (no new mint, `refreshReplays`); after it the grant's family is invalidated — `invalid_grant` for every refresh token of the grant, permanent (`healthy` does not revive it); access tokens untouched.
- Mail API 401 body is the bare `{"error":"INVALID_OAUTH_TOKEN"}` with `WWW-Authenticate: Bearer … error="invalid_token"`. The client is validated before the grant on refresh. Clock injectable (`FakeHQBase(…, now:)`).
- Scopes: only `GET signatures/manage` answers 403 `insufficient_scope`; general per-route scope enforcement is not modelled.

## Writing scenarios — gotchas
- With the app frontmost and presenter `succeed`, a dead session is repaired SILENTLY by automatic re-auth: to see the banner use `userCancel` (Sign In offered) or `hangUntilCancelled` (Cancel offered); switch to `succeed` only when the test wants the repair.
- A 15 s sync poll can meet a dead session before the test's action: pause the poll when the test must prove its own action met it; otherwise "promptly" is ≤ 5 s after the action. A grant already LATCHED makes a later Send fail fast with NO request (`sendRequests` stays 0) — assert via `unauthorized ≥ 1` and `sends == 0`.

## macOS 27 XCUITest gotchas
- A SwiftUI `Text` is a StaticText whose words are its VALUE (label empty); a `.combine`d group is a StaticText with the joined words. Banner reason and compose error reason are INSIDE the `.message` element's text; the banner spinner is `accessibilityHidden` (an attempt shows as `banner.reauth.cancel` existing); the compose error bar has no container (its `.message` IS the bar).
- `isEnabled` means something only for controls: an editable `TextEditor`, groups and the Application report Disabled — type after `waitUntilHittable`, not `waitUntilEnabled`.
- SwiftUI does NOT carry `.accessibilityIdentifier` to menu items (all report `menuAction:`) — match by title. Click a menu item WITHOUT opening its menu first (items are in the AX tree while closed; an already-open menu gets toggled shut → "Not hittable: MenuItem" at an off-screen frame).
- The compose window opens INSIDE the main window's frame: after any click in the main window use `ComposePage.bringToFront()` (Window menu item titled with the subject). Only one window is key; `app.windows.firstMatch` is the frontmost.
- `.safeAreaInset(edge: .top)` on a `NavigationSplitView` is ignored by its columns: the status banner is stacked `VStack(spacing: 0) { statusBanner; splitView }` in `MailWindow` (Herald/Views/RootView.swift) — a real bug the suite caught.
- Debugging: `xcrun xcresulttool export attachments --path <xcresult> --output-path <dir>` (UI hierarchy, screen recording); `xcrun xcresulttool get test-results activities --path … --test-id …` — check for "Found 1 interrupting element … from Application '<other app>'" before suspecting Herald. The runner is sandboxed and cannot write files; use `XCTAttachment(screenshot:)` with `.keepAlways`.

## Running rules
- Only when Alan says go (the suite drives the real mouse/keyboard and takes over the screen).
- Pre-run: screen unlocked (the script exits 3 otherwise; behind a locked screen `launch()` burns ~60 s per test then fails "Failed to activate application … Running Background"); `pgrep -fl "xcodebuild.*test|xctest"` shows no other project's run. Wait rather than fail; never kill other sessions' test processes or restart testmanagerd. No Accessibility/Automation prompt has appeared on this Mac once unlocked.
- Contention: other projects' concurrent test runs can wedge testmanagerd ("hung before establishing connection", "Timed out while enabling automation mode"); other apps' windows over Herald (e.g. Orchestric, a menu-bar monitor, the user working) cause interruption handling / "Timed out while synthesizing event" and centre-point clicks landing on the wrong window. Not Herald — rerun when quiet.
- macOS 27 beta testmanagerd can crash (SIGABRT in `-[XCTDApplicationLauncher initWithLaunchServicesFramework:]` at the first launch): first test fails "Lost connection to testmanagerd", the rest pass, xcodebuild exits 65, report in `~/Library/Logs/DiagnosticReports/testmanagerd-*.ips`. Rerun.
- Durations when healthy: full suite ~4.5–5.5 min incremental (first build into a fresh DerivedData-UITests ~10 min); Smoke 6–12 s/test, SignInFailure 16–24 s, DeadSessionRecovery 18–35 s, RecoveryAccessibility ~50 s.

## Current status (2026-09-27)
- 12 tests: Smoke 3, DeadSessionRecovery 4, SignInFailure 4, RecoveryAccessibility 1. Before U6b: 5 consecutive full runs 12/12 (b70b54a). After U6b: DeadSessionRecoveryTests 4/4 alone and one clean full run 12/12; other full reruns were contaminated by machine contention. The 5× consecutive rerun after U6b is PENDING Alan's go.

## History
- c292722 (U1) Debug-only launch mode + in-process fake HQBase; 05eb4ca refresh compare-and-set + held refresh responses.
- 67f181d (U2) HeraldUITests target, AccessibilityID, page objects, smoke; b382ba6 (U3/U4) recovery + failure scenarios, second origin, activation refusal.
- 7d53ef5 first run: banner-over-split-view fix, macOS 27 menu/window helpers; 176efc5 + b70b54a (U5) Outbox flake fix, per-test time limit, 5× green.
- dff1fed + 2000b47 (U6a) Debug bundle id, launch guard, script guards, DerivedData-UITests, release identity gate; 48720a9 + c67b468 + ed2278e (U6b) discriminating assertions, poll pause, new status keys, fake fidelity (audience binding, replay window, bare 401).
- Docs: plan `documents/plans/ui-tests-2026-09-27.md`, audit `documents/reports/ui-tests-audit-2026-09-27.md`, manual checklist `documents/reports/session-recovery-manual-checklist-v2-2026-09-27.md`.

## Observations
- [constraint] UI tests take over Alan's mouse, keyboard and screen: never start a UI-test run (scripts/ui-tests.sh) without his explicit go #uitest #running
- [invariant] UI-test mode exists only in Debug (Herald/UITestSupport is all #if DEBUG) AND only with -HeraldUITest <scenario>; a malformed request fatalErrors instead of falling back to the real Keychain/network #uitest #isolation
- [invariant] Three launch guards: ui-tests.sh refuses identity-changing args and any build not com.wizemann.herald.debug; HeraldApp.launch terminates an app that does not draw uitest.status within 20 s; verify-release-identity.sh keeps harness strings and Debug ids out of release builds #uitest #isolation
- [convention] Assertions are never vacuous: XCTUnwrap status fields (never ?? 0), 'healthy' means a success counter moved (apiSuccesses), 'did not happen under a latch' uses an app-side attempt counter (saveAttempts); each is mutation-checked #uitest #discriminating
- [fact] Status 2026-09-27: 12 tests in 4 classes; last clean full run 12/12 after U6b; the 5x consecutive rerun after U6b is pending Alan's go #uitest #status

## Relations
- relates_to [[Herald Testing Conventions]]
- relates_to [[Herald Build and Toolchain]]
- relates_to [[Sign-In Recoverability and the Presentation Watchdog]]
- relates_to [[Herald Architecture]]
- relates_to [[HQBase Mail API v1 Contract]]



## Update (2026-09-27 — R4 sidebar page objects)

- [fact] `SidebarPage` now drives the account card: `accountCard`, `addAccount()` (card → popover button `sidebar.accountCard.addAccount`), `switchAccount(to:)` (popover rows `sidebar.accountCard.account.<id>`), `signOut()` = the MENU BAR's "Sign Out…"-prefixed item (the sidebar has no Sign Out; Settings › Account's asks first). "Two accounts signed in" is `hasSeveralAccounts`/`waitForSeveralAccounts()` = the menu bar item titled "Sign Out of …" exists (`AppEnvironment.signOutMenuTitle`) — readable while a sheet blocks the window. Changed: `RecoveryAccessibilityTests.testRecoveryControlsHaveLabels`, `SignInFailureTests` (activation failure, sign-out failure, add-account refusal via `addAccount()`) — not yet run #uitest



## Update (2026-09-28 — 1.0 hardening runs, t-ddb84f9e)
- [fact] Suite is 13 tests. At 64a71c2 (HEAD after paging + compose fix): full runs 13/13 (345 s) and, on 7cfad7b, 12/13 where the one failure was "Timed out while synthesizing event" — the attached spindump showed Herald's main thread IDLE in the run loop, so not a Herald hang. The 5x consecutive run (t-23673507) is STILL NOT DONE: runs 2–5 died before any test ("Timed out while enabling automation mode", "test runner hung before establishing connection") while another session looped ShabuBox `xcodebuild test`, then the screen locked (ui-tests.sh exit 3) #uitest #status
- [procedure] Triage a "Timed out while synthesizing event": `xcresulttool export attachments`, open the Spindump .txt, find `Process: Herald` and read the main thread — parked in `mach_msg2_trap` under `-[NSApplication run]` means Herald was idle and the cause is contention (another app/test run). Gate reruns on `pgrep -f "[x]codebuild.* test"` being empty for ~60 s #uitest #debugging
- [fact] LoadMoreRow (paging) is untagged + `.selectionDisabled()` + `accessibilityHidden`; in the UI harness it shows only until the first `loadOlderConversations` returns false (no capped scopes in FakeHQBase), so no UI test covers keyboard navigation onto it — covered by reasoning, not automation #uitest #paging


- [done] 2026-09-28: 5x consecutive `./scripts/ui-tests.sh` at 68f145c — 5/5 green, 12/12 tests each (~283 s per run), gated on no other session's `xcodebuild test`. The suite is 12 tests (an earlier "13" in this note was a miscount). Closes t-23673507 #uitest #status
