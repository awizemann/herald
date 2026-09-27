---
title: Herald Architecture
type: note
permalink: hqbase-mac/architecture/herald-architecture
tags: [architecture, swift6]
source_paths: [Herald/App/AppEnvironment.swift, Herald/App/AccountGraph.swift, Herald/App/MailViewModel.swift, HeraldKit/Sources/HeraldKit/Sync/MailStore.swift, HeraldKit/Sources/HeraldKit/API/MailAPIClient.swift]
source_paths_inferred: false
source_sha: 1d190bc82f9ecd25a63d948b9c4f628f7ee7c32b
created: 2026-08-16
updated: 2026-09-27
reviewed: 2026-09-19
reviewed_by: audit:claude-code (background)
---

Layers (adapted from the ShabuBox standard §3 — strict Sendable boundary):
- `HeraldKit` (SPM package, all logic, testable, platform-agnostic where possible)
  - `API/` — `MailAPI` (generated from vendored OpenAPI via swift-openapi-generator + URLSession transport) wrapped by `nonisolated protocol MailAPIClient` (actor conforms) returning Sendable DTOs; `AuthManager` (OAuth PKCE, dynamic registration, Keychain); `AccountStore`.
  - `Sync/` — `SyncEngine` actor (poll + diff → store), `MailStore` @ModelActor (ONLY place @Model is touched), DTOs.
  - `Compose/` — `OutboxService` (drafts, attachments, send/reply).
- `Herald` (app target) — SwiftUI: `MailViewModel` (@Observable @MainActor, single UI state owner), views consume ONLY Sendable DTOs.

## Observations
- [decision] Drill-in: SELECTING a multi-message conversation opens its message list in the middle column (owner decision 2026-08-16, reversing an earlier explicit-open-only rule); ⎋ / back / arrowing to a single-message row returns to the list #drill-in
- [decision] Strict DTO boundary: views and MailViewModel consume only Sendable value DTOs; no @Model / @Query in views (why: faulted @Model reads in a body crash uncatchably mid-layout; DTO-only makes that class impossible) #boundary
- [decision] One @Observable @MainActor `MailViewModel` owns UI state; one @ModelActor `MailStore` owns all @Model access and #Predicate queries and maps @Model→DTO off-main #layers
- [decision] Server access behind `nonisolated protocol MailAPIClient` (an actor implements it) so tests inject a fake actor; protocol MUST be `nonisolated` under default-MainActor isolation or the actor cannot conform #protocols
- [decision] Auth is OAuth-only (no cookie fallback) — v1.1.0 removed the need; `AuthProviding` protocol still isolates it for tests #auth
- [decision] HTML bodies render in WKWebView from GET /messages/{id}/html fetched with the bearer token (WKWebView cannot send our Authorization header), loaded via loadHTMLString with a WKContentRuleList that blocks remote loads until the user trusts the sender #rendering

## Relations
- relates_to [[Herald Sync Model]]
- relates_to [[Herald Concurrency Rules]]
- relates_to [[HQBase Mail API v1 Contract]]

## Update (2026-08-15 — Auth layer as built)
- [fact] Auth/: `OAuthSession` is a nonisolated struct (stateless; per-attempt state lives in an `AuthorizationRequest` value); `AccountTokenProvider` actor serializes refresh (one in-flight refresh shared by concurrent callers, 60s expiry leeway, invalid_grant → `.reauthenticationRequired` + tokens cleared, transport errors keep tokens); `WebAuthenticationPresenter` → @MainActor `WebAuthenticationRunner` owns ASWebAuthenticationSession (non-ephemeral, so consent reuses the browser's HQBase login); `AuthCoordinator` (@MainActor) = discovery→registration(reuse client_id per origin)→PKCE→present→exchange→persist #auth
- [fact] `Account.userEmail` is not populated (v1 has no /me route); registration is kept on signOut only while another account uses the origin (P9a F), tokens dropped (and, since P8, the persisted `discovery.<origin>` too — see the 2026-09-26 update) #auth
- [fact] Compose/: `ComposeDraft` value (isDirty via didSet), `ComposePrefill` pure helpers (reply/reply-all recipients drop own addresses + order-preserving dedupe; Re:/Fwd: prefix idempotence; "> " quoting), `OutboxService` actor (create→update with version stamp, attach = stat-check → autosave → upload with sanitized filename, send routes .reply→/reply else /send, draft deleted only after success) #compose


## Update (2026-09-19 — audit F3: AppEnvironment split across four files)

- [fact] `AppEnvironment` (the composition root, `Herald/App/`) is ONE `@MainActor @Observable` type split across three files plus its graph type: `AppEnvironment.swift` owns the type, all stored state and the account lifecycle (start → restoreAccounts → activate → install → isCurrent/stopGraph, notifications, Dock badge, activation observing); `AppEnvironment+SignIn.swift` owns onboarding, re-auth and signOut; `AppEnvironment+Compose.swift` owns the compose sessions; `AccountGraph.swift` holds the per-account graph (sync/mail/outbox/signatures/notifier/wake). Was one 1217-line file (commit 02cef35) #files
- [gotcha] A Swift extension cannot hold stored properties and `private` is FILE scope, so the split forced the state the other files drive (`phase`, `isSigningIn`, `signInStage`, `accountIDs`, `auth`, `store`, `autoReauth`, the sign-in generation/cancellation handles) from `private`/`private(set)` to internal. They remain written only from `AppEnvironment` BY CONVENTION — the compiler no longer enforces it, so a view assigning one is a review catch, not a build error #access
- [invariant] `HQBaseAPIClient(origin:tokens:includeLabels: true)` is constructed at exactly ONE site and it stays in `AppEnvironment.swift` (`activate`) — a guard test pins it there #labels
- [decision] The launch restore of the accounts behind the first one runs from a RETAINED `restoreTask` over a `pendingRestoreIDs` queue: membership is checked before each `activate` and re-checked after it, and `cancelPendingRestore(accountID:)` (called from `signOut` before its first suspension, and from `stopGraph`) drops one account without stranding the others. Unretained, a sign-out during the loop re-installed the purged account with a live engine (audit C10) #restore



## Update (2026-09-26 — P8: account-store safety + offline launch)

- [fact] Keychain layout (service `com.wizemann.herald` shared by every RELEASE-config build on the Mac — older and newer release versions read/write the same items; Debug builds use `com.wizemann.herald.dev` and bundle id `com.wizemann.herald.debug` since 2026-09-27/U6a, see "Herald Build and Toolchain"): `accounts.index` = ONE JSON array of `Account` records; `tokens.<accountID>`; `client.<origin>` (dynamic-registration client_id; since P9a forgotten on sign-out of the origin's LAST account, kept while another account uses the origin); `discovery.<origin>` = persisted `OAuthConfiguration` (endpoints + scopes, no secrets; written at sign-in and by background rediscovery, deleted on sign-out). `<origin>` = `Account.normalize(origin).absoluteString`; today `accountID` == that same string #keychain-layout
- [invariant] The account index is NEVER silently written over when unreadable (audit W2 — old behaviour read it as `[]` and the next `add` wrote that back: every other account lost, tokens orphaned). Two cases: (a) valid JSON that is not a bare array (a newer build's format) → `accounts/add/remove` throw `AccountStoreError.indexUnreadable` and write nothing, ever; (b) bytes that are not JSON at all (corruption) → `accounts()` answers `[]` and the next write FIRST copies the bytes to `accounts.index.corrupt.<epoch-ms>` (a failed backup aborts the write), then heals — refusing forever would strand the user, since nothing in the app can clear the item. Empty data = missing. Launch maps (a) to onboarding WITH the explanation (`restoreAccounts` → `phase = .signedOut`, `signInError` set, `launch_failed(kind: restore)`), not "could not start" #account-index
- [invariant] Writability is checked BEFORE side effects: `AuthCoordinator.addAccount` reads the index (off main) after registration and before the browser opens (covers re-auth too — no consent minting a grant the store then refuses), and `signOut` reads it before revoking (no revoked grant left in an index it cannot rewrite) #account-index
- [invariant] Per-entry leniency: each index element is decoded on its own; an element this build cannot decode is hidden from `accounts()` but carried through every rewrite as its raw JSON, and a rewritten entry keeps keys this build does not know (the new encoding is overlaid on the stored object). `Account.init(from:)` requires only `origin` + `clientID` (id/label/scopes default, unknown keys ignored); the ENCODED shape is unchanged (all six keys) #account-index
- [gotcha] Older builds (the release app) decode the index with STRICT synthesized `Codable` and, on failure, read it as empty and OVERWRITE it. So while any older build may share the Keychain: never remove, rename or retype an existing index field, and never change the top level away from a bare array — only ADD keys. A test (`writtenIndexDecodesInOlderBuilds`) decodes what this build writes with a strict mirror of the release struct #account-index
- [decision] `store.add` MERGES into an existing record (in place, same position) via `Account.merging(over:)`: incoming wins except a nil `userEmail` and a `label` equal to `Account.defaultLabel(for:)` (host), which keep the stored value — a re-auth builds its record from scratch. No `version` field: additive keys + tolerant decode cover it, and a version the old build can't read would buy nothing #account-index
- [decision] Add Account (onboarding `signIn(originText:)` → `performSignIn(refusesExistingOrigin: true)`) refuses BEFORE OAuth when the origin (compared via `AppEnvironment.originKey`: lowercased, default :443 and trailing root dot dropped — comparison only, never a Keychain key) is live in `graphs` or present in the Keychain index, or when the index is unreadable; message: "You're already signed in to <host>. If its session has expired, use Sign In on that account instead." Re-auth paths pass `false`. Interim guard for W1 until identity becomes origin+sub (multi-account) #add-account-guard
- [decision] Activation needs no network (audit W4): `AuthCoordinator.tokenProvider(for:)` reads the persisted discovery (validated: same normalized origin AND `OAuthDiscovery.endpointsAreTrusted`, else ignored) and builds the provider with a `DiscoveringRefresher` that resolves endpoints at REFRESH time: this launch's live discovery → else the persisted copy (never waits on the network) → else awaits a live discovery. A background discovery started at activation (deduped per origin) fills the in-memory cache and rewrites the persisted copy (only while an account for the origin is still in the index), which is how a stale copy heals. Offline: graph installs, cached mail readable, sync fails with a transport error and retries. The in-memory `configurations` cache holds only LIVE results, so `addAccount` always signs in against endpoints confirmed this launch. `signOut` bumps a per-origin sign-out generation; a provider built before it refuses to resolve endpoints afterwards (`OAuthError.unknownAccount`, not retryable) — otherwise a refresh retrying the discovery the sign-out cancelled would rediscover the origin and spend the just-revoked grant. Residual (accepted): a background discovery's index-check + persist is not atomic with a concurrent sign-out, so a `discovery.<origin>` item can survive for an origin nobody is signed in to — harmless, `addAccount` never reads it and overwrites it #offline-activation



## Update (2026-09-26 — P7)
- [fact] `client.<origin>` is no longer write-once: `AccountStore.forgetClientID(_:for:)` compare-and-deletes it when the server refuses the client (`invalid_client`/`unauthorized_client` on refresh, callback or code exchange), so the next sign-in re-registers. Every `AccountStore` conformer (incl. test fakes) must implement it. `AccountTokenProvider(origin:clientID:)` carries the id to forget. Details: "Sign-In Recoverability and the Presentation Watchdog" #dead-client #keychain
- [invariant] `tokens.<accountID>` is written by a refresh (and cleared on `invalid_grant`) ONLY via `AccountStore.setTokens(_:for:ifRefreshTokenIs:) -> Bool` — compare-and-set on the stored refresh token, so a refresh racing a sign-in never overwrites the new grant (05eb4ca). A protocol requirement with NO default: every conformer (incl. `InMemoryAccountStore` and test fakes; wrappers forward to their backing store) implements it atomically. `KeychainAccountStore` now takes its lock for every token read/write too; the lock is not re-entrant, so private `loadTokens`/`storeTokens` are the only token helpers callable under it. Sign-in still uses the plain `setTokens` #keychain #race


## Update (2026-09-26 — P9a: client-id resolution and sign-out ordering)
- [decision] The `client_id` a refresh is sent as is the ACCOUNT RECORD's (`accounts.index`), read at refresh time by `AccountTokenProvider` — never captured when the provider/`DiscoveringRefresher` is built (P7 made ids change mid-life). A refusal for a request sent as a no-longer-current id is superseded (retry once as the current id; no latch/clear/forget/announce). Details: "Sign-In Recoverability and the Presentation Watchdog" (P9a update) #client-id #keychain-layout
- [decision] `AuthCoordinator.signOut` order: index readable check → capture the live discovery → bump the per-origin sign-out generation, evict in-memory discovery, cancel background discovery → revoke (endpoint from captured → persisted → uncached live discovery; client id from the record; store re-read once afterwards and a refresh token that changed meanwhile is revoked too) → remove → if no remaining index entry uses the origin: evict `discovery.<origin>` and compare-and-delete `client.<origin>`. Bumping before the revoke stops a live provider rotating the grant mid-revoke (R2 orphaned). A provider refused by the generation now announces a re-auth death (not transport) #sign-out
- [gotcha] Future same-origin multi-account: the generation bump (and hence the I-path re-auth death) is per ORIGIN, so signing out one account would strand the other account's providers on that origin — revisit when multi-account per origin lands #sign-out #residual



## Update (2026-09-26 — composition-root branch for UI tests, commit c292722)
- [decision] `HeraldApp.makeEnvironment()` is the one branch: `#if DEBUG` + `UITestHarness.launched` (non-nil only with `-HeraldUITest <scenario>`) → `harness.environment`; otherwise the real `AppEnvironment(usage:)`. The harness static also feeds `.defaultAppStorage` on every scene (main, compose, Settings), the `UITestCommands` menu and the `uitest.status` overlay — all inside `#if DEBUG` #composition-root
- [fact] `AppEnvironment.init` seams added for it, defaults = previous behaviour: `makeMailContainer` (on-disk `MailStoreContainer.defaultStoreURL`), `apiSession` (`URLSession.shared` for `HQBaseAPIClient`), `makeEventChannels` (`URLSessionMailEventChannels`), `routesNotificationClicks` (installs the `UNUserNotificationCenter` delegate); `defaults` is now internal. `UpdateService.startsUpdater(arguments:isRunningUnderTests:)` and `UsageAnalytics.disablingArguments` (Debug: `-HeraldUITest`) stand down on the flag alone #composition-root
