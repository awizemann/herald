---
title: Sign-In Recoverability and the Presentation Watchdog
type: note
permalink: hqbase-mac/decisions/sign-in-recoverability-and-the-presentation-watchdog
tags: [auth, oauth, ux, concurrency]
source_paths: [Herald/App/AppEnvironment.swift, Herald/App/AppEnvironment+SignIn.swift, Herald/App/AppEnvironment+Compose.swift, Herald/App/AutoReauthPolicy.swift, Herald/App/MailViewModel.swift, Herald/App/SignatureSettingsModel.swift, Herald/Views/RootView.swift, Herald/Views/SidebarView.swift, Herald/Compose/ComposeViewModel.swift, Herald/Compose/ComposeWindow.swift, HeraldKit/Sources/HeraldKit/Auth/AuthorizationPresenter.swift, HeraldKit/Sources/HeraldKit/Auth/AuthCoordinator.swift, HeraldKit/Sources/HeraldKit/Auth/AccountTokenProvider.swift, HeraldKit/Sources/HeraldKit/Auth/OAuthError.swift, HeraldKit/Sources/HeraldKit/Auth/AccountStore.swift, HeraldKit/Sources/HeraldKit/API/AuthenticatingMiddleware.swift, HeraldKit/Sources/HeraldKit/Sync/MailEventSocket.swift, HeraldKit/Sources/HeraldKit/Sync/URLSessionMailEventChannel.swift]
source_paths_inferred: false
source_sha: 5bf365e9eb97afb117962adc5d9a8d5f56b9053f
created: 2026-09-05
updated: 2026-09-27
reviewed: 2026-11-19
reviewed_by: audit:claude-code (background)
---

## Observations
- [decision] WebAuthenticationRunner watchdog timer: 45s advisory + 10min hard deadline to detect wedged ASWebAuthenticationSession; Cancel is the fast path #watchdog
- [decision] Dead-session latch in AccountTokenProvider fires only on post-refresh 401 with explicit error="invalid_token"; bare 401 still gets one refresh+retry #dead-session-latch
- [decision] Routing to re-auth by account ID (not provider/grant); sticky `.needsReauth` state until fresh graph install; self-heal probes first before attemptAutomaticReauthentication #dead-session-routing
- [decision] Interactive vs automatic re-auth are mutually exclusive via generation stamping and policy claims; generation bump on cancel ensures stale re-auth returns don't release newer Sign In #cancel-gen
- [decision] Scope refusals at sign-in registration: proactive check in `clientID` compares stored scopes to requested scopes; if stale (pre-scope-tracking registration or fewer scopes), re-registers before the browser window; reactive catch at authorization rethrows as `OAuthError.scopesRefused` and forgets the registration so the next attempt re-registers #scope-refusal
- [constraint] Composers stay alive through re-auth via rebindComposeSessions; dead-session failure is sticky until rebind or status change #compose-reauth

## Relations
- relates_to [[Automatic Re-auth Policy (frontmost, deferred, rate-limited)]]
- relates_to [[Herald Concurrency Rules]]
- relates_to [[Herald Error Handling and Security Rules]]
- relates_to [[Herald Architecture]]
- relates_to [[HQBase Mail API v1 Contract]]
- relates_to [[Herald Multi-Account, Notifications, Drafts and Search Design]]
