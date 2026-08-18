---
title: Herald Architecture
type: note
permalink: hqbase-mac/architecture/herald-architecture
tags:
- architecture
- swift6
created: 2026-08-16
updated: 2026-08-16
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
- [fact] `Account.userEmail` is not populated (v1 has no /me route); registration is kept on signOut, tokens dropped #auth
- [fact] Compose/: `ComposeDraft` value (isDirty via didSet), `ComposePrefill` pure helpers (reply/reply-all recipients drop own addresses + order-preserving dedupe; Re:/Fwd: prefix idempotence; "> " quoting), `OutboxService` actor (create→update with version stamp, attach = stat-check → autosave → upload with sanitized filename, send routes .reply→/reply else /send, draft deleted only after success) #compose
