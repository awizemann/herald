---
title: OAuth Registration Scope Coverage
type: note
permalink: hqbase-mac/decisions/oauth-registration-scope-coverage
tags: [auth, oauth]
source_paths: [HeraldKit/Sources/HeraldKit/Auth/AuthCoordinator.swift, HeraldKit/Sources/HeraldKit/Auth/AccountStore.swift, HeraldKit/Sources/HeraldKit/Auth/OAuthSession.swift, HeraldKit/Tests/HeraldKitTests/Auth/RegistrationScopeTests.swift]
source_paths_inferred: false
source_sha: b3d494ce6fb5e361eda1d81a80812f21680c65d2
created: 2026-11-19
updated: 2026-11-19
---

Shipped in 1.1.2 (commit 065da8a) after sign-in to HQBase 1.4.5 failed with "The following scopes are invalid: signatures:manage".

## Observations
- [gotcha] HQBase refuses an authorize request for any scope the dynamically registered client did not register (invalid_scope), even when discovery advertises it #auth
- [decision] Registered scopes are stored beside the client_id (Keychain key clientScopes.<origin>); a saved registration is reused only while its scopes cover the requested scopes, and unknown scopes count as stale #auth
- [decision] An invalid_scope/invalid_target sign-in callback forgets the registration and throws OAuthError.scopesRefused; no automatic retry, to avoid a second browser window #auth
- [convention] Callback query values are form-decoded (+ is a space) so error_description reads correctly #auth
- [gotcha] The Debug dev copy has its own Keychain namespace, so it cannot reproduce a stale registration in the release app #testing

## Relations
- relates_to [[Sign-In Recoverability and the Presentation Watchdog]]
- relates_to [[Herald Error Handling and Security Rules]]
- builds_on [[HQBase Mail API v1 Contract]]
