---
created: 2026-08-19
updated: 2026-08-19
source_sha: 35ba57be0606d427a5aa36e1500b7f685b444351
source_paths: HeraldKit/Sources/HeraldKit/Auth
source_paths_inferred: false
---

# Authentication and Accounts

Herald uses OAuth 2.1 PKCE to sign in to HQBase. Tokens are stored in the macOS Keychain; multiple accounts can be added.

## Sign-in flow

`AuthCoordinator` (`HeraldKit/Sources/HeraldKit/Auth/AuthCoordinator.swift:11`) orchestrates:

1. **Service discovery** — Fetch the `.well-known/oauth-authorization-server` metadata from the HQBase instance to learn the authorization and token endpoints.
2. **Dynamic client registration** — `DynamicClientRegistration` (`HeraldKit/Sources/HeraldKit/Auth/DynamicClientRegistration.swift:11`) registers a new OAuth client with HQBase, receiving a client ID (one per app install; PKCE means no client secret is needed).
3. **Authorization request** — Launch a system web view via `WebAuthenticationPresenter` (`HeraldKit/Sources/HeraldKit/Auth/AuthorizationPresenter.swift:22`) with a PKCE code-challenge.
4. **Token exchange** — HQBase returns an authorization code; `AuthCoordinator` exchanges it for access and refresh tokens.
5. **Keychain storage** — `KeychainAccountStore` (`HeraldKit/Sources/HeraldKit/Auth/AccountStore.swift:41`) stores the account and tokens securely.

See `HeraldKit/Sources/HeraldKit/Auth/Account.swift:9` for the `Account` struct and `OAuthTokens` struct.

## Account store

`AccountStore` (protocol at `HeraldKit/Sources/HeraldKit/Auth/AccountStore.swift:11`) abstracts account and token persistence. `KeychainAccountStore` (`AccountStore.swift:41`) implements it, storing accounts as Keychain items keyed by account ID.

Multiple accounts are supported; each is stored independently and can be removed.

## Token refresh

`AccountTokenProvider` (`HeraldKit/Sources/HeraldKit/Auth/AccountTokenProvider.swift:20`) is an actor that:

- Holds the current account and tokens
- Implements `BearerTokenProvider` so the API client can fetch a token synchronously
- Refreshes the token when it expires (via the refresh token)
- Re-fetches the account from the store on refresh to pick up changes

The API client calls `token()` on `AccountTokenProvider` before every request, which blocks if a refresh is in progress.

## OAuth details

- **Flow** — OAuth 2.1 PKCE (authorization code with code verifier, no client secret sent)
- **Presenter** — `WebAuthenticationPresenter` uses `ASWebAuthenticationSession` to launch a system web view
- **Client registration** — Dynamic client registration; the client ID is stored locally, not hardcoded
- **Scopes** — `mail:read` and `mail:write` (HQBase Mail API v1)

---
_Last updated: 2026-08-19 — authentication and accounts; fact-checked against the code for v0.3.0_