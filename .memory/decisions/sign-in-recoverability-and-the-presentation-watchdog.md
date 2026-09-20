---
title: Sign-In Recoverability and the Presentation Watchdog
type: note
permalink: hqbase-mac/decisions/sign-in-recoverability-and-the-presentation-watchdog
tags: [auth, oauth, ux, concurrency]
source_paths: [Herald/App/AppEnvironment.swift, Herald/Views/OnboardingView.swift, HeraldKit/Sources/HeraldKit/Auth/AuthorizationPresenter.swift, HeraldKit/Sources/HeraldKit/Auth/AuthCoordinator.swift]
source_paths_inferred: false
source_sha: 7e5eb159db68edaac988bfd21ae27c5ae670639d
created: 2026-09-05
updated: 2026-09-05
reviewed: 2026-09-09
reviewed_by: audit:claude-code (background)
---

Herald #9 (bermanto, v0.4.0): sign-in hung with a spinner and no browser window, unrecoverable without force-quitting. Root cause is out of process — `ASWebAuthenticationSession.start()` returns `true` once the request reaches the per-user authentication agent, and a wedged agent neither presents nor ever calls back (it survives app relaunches, which matches the report). Nothing in Herald can fix that agent, so the fix is to SURVIVE it. Landed on `fix/signin-hang-recovery` for 0.4.1.</content>

## Observations
- [fact] `ASWebAuthenticationSession.start() == true` only means the request reached the out-of-process per-user authentication agent; a wedged agent presents no window and never invokes the completion handler, so the awaiting continuation is simply never told anything — not a missing resume in our code #aswebauth
- [decision] `WebAuthenticationRunner.authorize` arms a 45s presentation watchdog AFTER `start()` succeeds (`presentationDeadline`), cancels the session and fails with `.webAuthenticationFailed(presentationTimeoutMessage)`; the watchdog Task is torn down inside `finish(_:with:)`, the single resumption point, so a slow-but-successful consent is never killed and no timer leaks. Deadline, sleep and a `WebAuthenticationDriving` factory are injected so it is testable without a window server #watchdog
- [decision] `AppEnvironment` retains the interactive sign-in (`signInCancellation`) and stamps it with a monotonic `signInGeneration`; `cancelSignIn()` bumps the generation AND clears `isSigningIn`/`signInStage` itself rather than relying on the task unwinding — a step that cannot be interrupted (blocked SecItem, dead agent) then still leaves a usable screen. A stale generation refuses to install its account, so a consent that lands after the user gave up cannot yank them into a mailbox #cancel
- [constraint] Automatic re-auth passes `generation: nil` and therefore never touches `isSigningIn`/`signInStage`/`presentsAddAccount`; a user cancel cannot abort an automatic attempt and vice versa. User-INITIATED re-auth gets a generation and is cancellable like a first sign-in #auto-reauth
- [decision] Keychain stays a synchronous `nonisolated` `AccountStore` behind os_unfair_lock; the auth path instead dispatches its calls off the main actor (`AuthCoordinator.offMain`, plus `loadAccounts()` at launch). A blocked `SecItem` call is uninterruptible either way — what this buys is a main actor that keeps drawing and can honour Cancel (closes t-8a1c0012) #keychain

## Relations
- relates_to [[Automatic Re-auth Policy (frontmost, deferred, rate-limited)]]
- relates_to [[Herald Concurrency Rules]]
- relates_to [[Herald Error Handling and Security Rules]]


## Update (2026-09-05 — bounded auth HTTP, discovery cache eviction)

- [decision] `AuthCoordinator.defaultSession` is a dedicated ephemeral `URLSession` (15s request / 30s resource, `reloadIgnoringLocalCacheData`, no cookie storage), NOT `URLSession.shared` — whose 7-day resource timeout meant a server that accepted the connection and went quiet could hang discovery or the token exchange indefinitely. `makeSession(requestTimeout:resourceTimeout:)` is the injectable seam #timeouts
- [gotcha] The per-launch discovery cache is keyed by normalized ORIGIN; `signOut` evicted it under `account.id`, so the entry never went away and a same-launch re-add after a server reinstall could reuse the previous install's endpoints. Fixed via `cacheKey(_:)`, with a regression test #discovery-cache
- [fact] `AuthCoordinator.addAccount(origin:onStep:)` reports `AuthStep` (discovering, checkingRegistration, registering, presenting, exchanging, saving) on the main actor and logs each `.public`; the app maps them to `AppEnvironment.SignInStage`, which owns the user-facing copy and adds `.activating` #stages


## Update (2026-09-05 — adversarial audit findings, all fixed before commit)

- [gotcha] AuthenticationServices gives NO "the window appeared" signal, so any timer armed after `start()` also covers a human reading the consent page and fetching a second factor. A 45s HARD deadline would tear down a live consent screen — so the timer is now split: a 45s ADVISORY that only logs (`presentationWarning`) and a 10-minute hard `presentationDeadline`. Never shorten the hard deadline; Cancel is the fast path #watchdog
- [gotcha] `addAccount` persists the account and tokens BEFORE the app can see a cancel, so a cancelled sign-in used to reappear at the next launch via `restoreAccounts`. The stale-generation branch in `performSignIn` now calls `auth.signOut(account)` to undo it (which also revokes the refresh token) — a Cancel that only skips `install` is a deferred sign-in, not a cancel #cancel
- [gotcha] An interactive re-auth claims the account in `AutoReauthPolicy` and only releases it when its task returns — which never happens for the securityd-stall case, leaving the banner spinning and both the retry button and automatic re-auth dead for the launch. `cancelInteractiveSignIn()` releases the claim (`autoReauth.finish(succeeded: false)`) immediately, and the normal completion path only finishes when its generation is still current #auto-reauth
- [decision] `beginInteractiveSignIn` CANCELS the previous claim rather than orphaning it (Add Account and the re-auth banner can interleave), and `signOut` cancels an interactive re-auth for the account it is removing — cancel only, never await, since the task may never return #cancel
- [fact] The re-auth banner (Herald/Views/RootView.swift) shows Cancel next to its spinner only for a USER-initiated attempt (`AppEnvironment.isCancellableReauthentication`); an automatic attempt withdraws on its own and gets no button #ui
