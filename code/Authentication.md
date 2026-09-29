---
created: 2026-09-29
updated: 2026-09-29
source_sha: 2bfa6bee79e5baf669c80ee8cf23b74d74feaead
source_paths: HeraldKit/Sources/HeraldKit/Auth
source_paths_inferred: false
---

# Authentication

Herald uses OAuth 2.1 PKCE (Proof Key for Code Exchange) to sign in to HQBase. The auth flow is handled by `AuthCoordinator`; accounts and tokens live in `AccountTokenProvider` (actor) and `KeychainAccountStore`.

## Core types

**Account** (Sendable struct, Codable)
- `id: String`, `userID: String`, `email: String`, `hqbaseOrigin: URL`.
- Stored in Keychain (SecretStore) after sign-in; restored on launch.

**OAuthTokens** (Sendable struct, Codable)
- `accessToken: String`, `refreshToken: String`, `expiresAt: Date`.
- Also in Keychain; rotated by `AccountTokenProvider.refreshIfNeeded()`.

**AuthCoordinator** (final class)
- Drives the sign-in state machine: `AuthStep.accountDiscovery` → `.register` → `.authorize` → `.exchangeCode`.
- Delegates to `AuthorizationPresenter` (usually `WebAuthenticationPresenter`, which uses `ASWebAuthenticationSession`).
- Calls back to your app's handler (e.g., AppEnvironment) after each step succeeds.

**AccountTokenProvider** (actor, implements `BearerTokenProvider`)
- Middleware-friendly way to get a valid bearer token without blocking.
- Automatically refreshes tokens when they're about to expire (via `AccountStore.updateTokens`).
- Lives in AccountGraph so each account has its own token cycle.

**KeychainAccountStore** (nonisolated final class)
- Persists Account and OAuthTokens in Keychain with a per-account key prefix.
- No in-memory cache; every read hits Keychain (small cost, no staleness bugs).

## Key invariants

1. **One token per account.** Account IDs come from HQBase's `/api/v1/discovery` and are stable across refreshes.
2. **Refresh before expiry.** AccountTokenProvider refreshes at 80% of the token's lifetime, not on-demand after expiry.
3. **Sign-in is modal.** Only one AuthCoordinator is active at a time (enforced in AppEnvironment); parallel sign-ins are rejected.
4. **Keychain survives app restarts.** No in-memory state; Keychain is the source of truth for accounts and tokens.

## When you touch this

- Adding a new account field (e.g., display name)? Update the Account struct, bump Keychain key version.
- Changing the OAuth flow? Edit AuthCoordinator.runStep() and test against a local HQBase (see wiki/Local-HQBase-Testing.md).
- Token refresh failing? Check AccountTokenProvider.refreshIfNeeded() logs; 401 from the API will trigger AutoReauthPolicy (see [[automatic-re-auth-policy-frontmost-deferred-rate-limited]]).
