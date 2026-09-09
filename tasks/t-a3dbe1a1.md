---
id: t-a3dbe1a1
title: Herald #9: sign-in hangs with spinner, no browser window (post HQBase-reinstall registration reset) + onboarding has no cancel/retry
status: done
added: 2026-09-05
priority: high
---

## Description

bermanto report on v0.4.0, detailed: discovery 200s, new client ID valid in browser, but ASWebAuthenticationSession never presents; isSigningIn cleared in defer that can't run while addAccount is suspended; onboarding Sign In has no cancel, task handle not retained, no timeout. Two workstreams: (1) root-cause the non-presenting session (suspect: presentation anchor at the initial-connection window state, or a hang before presenter entry — e.g. registration/discovery path after reinstall); (2) recoverable login state: cancel/retry cancels the real task, stage diagnostics, pending-presenter test per his suggestion.

## Plan



## Artifacts

Branch `fix/signin-hang-recovery` (off main @ v0.4.0), not pushed.

Code:
- `HeraldKit/Sources/HeraldKit/Auth/AuthCoordinator.swift` — `AuthStep`/`AuthStepHandler` + `addAccount(origin:onStep:)`; `offMain` (Task.detached) around every AccountStore call; async `loadAccounts()`; dedicated `defaultSession`/`makeSession(requestTimeout:resourceTimeout:)` (15s/30s) replacing `URLSession.shared`; `signOut` now evicts the discovery cache by normalized origin (`cacheKey`) instead of `account.id`.
- `HeraldKit/Sources/HeraldKit/Auth/AuthorizationPresenter.swift` — `WebAuthenticationDriving` seam + `ASWebAuthenticationDriver`; 45s presentation watchdog armed after `start()` succeeds, torn down in `finish`; injectable deadline/sleep/driver factory.
- `Herald/App/AppEnvironment.swift` — `SignInStage` (+ message/logName), `signInStage`, retained `signInCancellation`, `signInGeneration`, `cancelSignIn()`, `ownsSignInUI`; `performSignIn(originText:generation:)` (generation nil == automatic); user-initiated re-auth is generation-stamped and cancellable; boot uses `loadAccounts()`.
- `Herald/Views/OnboardingView.swift` — stage caption under a spinner; Cancel shown whenever `isSigningIn` (both the first-run screen and the sheet), wired to `cancelSignIn()`; a11y labels.
- `CHANGELOG.md` — `## [Unreleased] / Fixed`.

Tests: `HeraldKit/Tests/HeraldKitTests/Auth/SignInRecoveryTests.swift` (watchdog fires; watchdog torn down on a slow success; stalled server → bounded transport error; session timeouts), additions to `AuthCoordinatorTests.swift` (step order; signOut→re-add re-runs discovery), `HeraldTests/SignInRecoveryTests.swift` (pending presenter stuck at `.waitingForBrowser`; cancel clears state and a second attempt runs; late completion after cancel does not install; stalled discovery named; blocking Keychain read leaves the main actor free).

Memory: `.memory/decisions/sign-in-recoverability-and-the-presentation-watchdog.md`. Closed t-8a1c0012 (Keychain off main, boot path included).

Out of scope, still open: plan item E "Open in browser" fallback — parked pending the reporter's frozen-vs-responsive answer on the issue.

