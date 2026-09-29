---
title: Automatic Re-auth Policy (frontmost, deferred, rate-limited)
type: note
permalink: hqbase-mac/decisions/automatic-re-auth-policy-frontmost-deferred-rate-limited
tags: [auth, ux, oauth]
source_paths: [Herald/App/AutoReauthPolicy.swift, Herald/App/AppEnvironment.swift, Herald/App/AppEnvironment+SignIn.swift, Herald/App/AppEnvironment+Compose.swift, Herald/App/MailViewModel.swift, Herald/Views/RootView.swift, HeraldKit/Sources/HeraldKit/Auth/AuthorizationPresenter.swift, HeraldKit/Sources/HeraldKit/Auth/AccountTokenProvider.swift]
source_paths_inferred: false
source_sha: 2bfa6bee79e5baf669c80ee8cf23b74d74feaead
created: 2026-09-04
updated: 2026-09-26
reviewed: 2026-09-29
reviewed_by: audit:claude-code (background)
---
Current policy for Herald re-running consent by itself (verified at HEAD 177f09f against Herald/App/AutoReauthPolicy.swift and AppEnvironment+SignIn.swift). Mechanics of detection, Cancel and heal: [[Sign-In Recoverability and the Presentation Watchdog]].

## Policy
- [decision] Herald re-runs OAuth consent BY ITSELF when a session dies, gated by `AutoReauthPolicy` (a dependency-free value type): only while Herald is frontmost, at most one attempt in flight per account, and at most one AUTOMATIC attempt per `retryInterval` (10 min) per account WHATEVER its outcome. The ReauthBanner is the fallback and reads "Signing you back in…" while an attempt runs #auto-reauth
- [decision] Cooldown (`finish(accountID:succeeded:)`; in-flight entries remember whether they were automatic): an automatic attempt starts it on success AND failure — a success used to clear it, so a 401 that keeps escalating without the `invalid_token` challenge (no latch; sync/socket still raise the banner) reopened consent after every successful flash (audit N1). A USER attempt (`beginUserInitiated`) ignores frontmost and cooldown but not one-in-flight; its success clears the cooldown, its failure or Cancel starts it. `finish` after `forget` is a no-op #cooldown
- [decision] The banner's Cancel on an automatic attempt (`cancelAutomaticReauthentication`) finishes it as unsuccessful immediately: cooldown starts, so Herald does not reopen the window the user just closed; the user's own Sign In still works at once #cooldown
- [fact] Fully headless re-auth is impossible (ASWebAuthenticationSession always shows a window); it completes instantly only because `WebAuthenticationPresenter` is non-ephemeral and sees the live HQBase cookie session. The accepted cost is a flashing window — hence the frontmost rule #flash

## Triggers & deferral
- [gotcha] The gates DEFER, they do not consume: `MailViewModel` announces only the TRANSITION into `.needsReauth` (one death = one request), usually while Herald is in the background. `retryAutomaticReauthentication()` re-offers the repair on app activation (`setWindowActive`) and on selection change; without those retriggers the feature would almost never fire #deferral
- [fact] Every surface announces: any request through the account's `AccountTokenProvider` (sync, socket, send, autosave, open, mark-read, signatures) reports via the provider hook → `reportSessionDeath` → `MailViewModel.reportSessionExpired()` → `attemptAutomaticReauthentication`. Several reporters for one death yield ONE attempt (per-grant dedupe + transition-only announce) #single-signal
- [fact] `performSignIn` with `generation: nil` is the quiet variant (no `isSigningIn`/`signInError`/`presentsAddAccount`); a failed automatic attempt's reason goes to `reauthErrors` for the banner's detail line. `account_reauthenticated` carries `automatic` so machine attempts stay out of the human funnel #quiet-signin

## Scope & heal
- [constraint] Automatic attempts are scoped to the SELECTED account (a consent window for an account the user is not looking at is confusing), yet a re-auth never selects the account it repairs (`select: graphs[id] == nil`). Sign-out CANCELS the attempt without awaiting it (a wedged agent hung sign-out) and `forget`s the account; a late consent finds no graph and is signed back out #scoping
- [decision] Heal before consent: `attemptAutomaticReauthentication` first probes `healIfSessionRecovered` — if the store holds a DIFFERENT grant than the one the session died on (another Herald process signed in), the account is re-installed `select:false` with no window; `retryAutomaticReauthentication` also probes every non-selected `.needsReauth` account. Heals have their own limit (`allowsHeal`/`recordHeal`: one per `retryInterval` per account, not the consent cooldown, cleared by `forget`) because two processes sharing one dead session see each other's refreshes as "a different grant" #heal

## Relations
- relates_to [[HQBase Mail API v1 Contract]]
- relates_to [[Herald Architecture]]
- relates_to [[Sign-In Recoverability and the Presentation Watchdog]]
- relates_to [[Herald Multi-Account, Notifications, Drafts and Search Design]]

## History
- 2026-09-04 cc61d02 (t-16dd066e) initial policy · 2026-09-26 P2 74ca7b6 every surface announces · P3 9cead5e Cancel starts cooldown · P6 9b3101c no selection on re-auth, non-awaiting sign-out · P9b 70c288a outcome-independent cooldown, heal probe + heal interval
