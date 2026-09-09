---
title: Automatic Re-auth Policy (frontmost, deferred, rate-limited)
type: note
permalink: hqbase-mac/decisions/automatic-re-auth-policy-frontmost-deferred-rate-limited
tags: [auth, ux, oauth]
source_paths: [Herald/App/AutoReauthPolicy.swift, Herald/App/AppEnvironment.swift, Herald/App/MailViewModel.swift, Herald/Views/RootView.swift, HeraldKit/Sources/HeraldKit/Auth/AuthorizationPresenter.swift]
source_paths_inferred: false
source_sha: 997b6e7907e5ea5494e1ef034084f406daf4c085
created: 2026-09-04
updated: 2026-09-04
reviewed: 2026-09-04
reviewed_by: audit:claude-code (background)
---

## Observations
- [decision] Herald re-runs OAuth consent BY ITSELF when a session expires: `AutoReauthPolicy` (Herald/App/AutoReauthPolicy.swift) allows an attempt only when Herald is frontmost, one in flight per account, and not within 10 min of an attempt that fixed nothing; the ReauthBanner stays up as the fallback and shows "Signing you back in…" while an attempt runs (t-16dd066e, commit cc61d02) #auto-reauth
- [gotcha] The gates DEFER, they do not consume: MailViewModel announces only the TRANSITION into `.needsReauth` (one expiry = one request), and expiries are almost always discovered while Herald is in the background — so `AppEnvironment.retryAutomaticReauthentication()` re-offers the repair on app activation and on account selection change. Without those retriggers the feature would essentially never fire #deferral
- [fact] Fully headless reauth is impossible (ASWebAuthenticationSession always shows a window); it completes instantly only because `WebAuthenticationPresenter` is non-ephemeral and sees the live HQBase cookie session. The accepted cost is a window that flashes — hence the frontmost rule #flash
- [constraint] Scoped to the SELECTED account: a sign-in installs and selects the account it repairs, so auto-repairing a background account would yank the window off the mail being read; sign-out cancels and awaits an in-flight attempt so its `install` cannot resurrect the account #scoping
- [fact] `performSignIn(isAutomatic:)` is the quiet variant — no isSigningIn/signInError/presentsAddAccount — and now reports a failed `activate` as `.failed`; the `account_reauthenticated` usage event carries an `automatic` prop so machine attempts are not counted in the human funnel #quiet-signin

## Relations
- relates_to [[HQBase Mail API v1 Contract]]
- relates_to [[Herald Architecture]]
