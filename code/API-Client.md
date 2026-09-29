---
created: 2026-09-29
updated: 2026-09-29
source_sha: 2bfa6bee79e5baf669c80ee8cf23b74d74feaead
source_paths: HeraldKit/Sources/HeraldKit/API
source_paths_inferred: false
---

# API Client

The HTTP client is `HQBaseAPIClient` (actor), auto-generated from the HQBase Mail API v1 OpenAPI spec via `swift-openapi-generator`. It speaks Sendable DTOs (no @Model in the request/response) and integrates OAuth bearer tokens via `AccountTokenProvider`.

## Architecture

**HQBaseAPIClient** (actor, implements `MailAPIClient` protocol)
- Wraps the generated `Client` from the vendored `HeraldAPI` SPM target.
- Methods: `listMailboxes()`, `listConversations(...)`, `getMessage(id:)`, `sendMessage(draft:)`, `listChanges(...)`, etc.
- All Sendable, all actor-safe.

**AuthenticatingMiddleware** (nonisolated struct, implements `ClientMiddleware`)
- Injected into the OpenAPI client to attach bearer tokens to every request.
- On 401, it calls `AccountTokenProvider.refreshIfNeeded()` and retries once.
- Logs on error (logger.warning for expected: 401, offline; logger.error for unexpected: decode failure).

**MailAPIError** (enum, Sendable)
- Variants: `.transportFailure(TransportFailure)`, `.httpError(HTTPError)`, `.decodingFailure(String)`, `.offline`.
- All endpoints throw this, so callers have a consistent error surface.

**HeraldAPI target** (nonisolated)
- The swift-openapi-generator output. Builds WITHOUT `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` (strict concurrency is satisfied by Sendable types). Lives in its own SPM target to keep generated code out of the main bundle.
- See [[generated-api-client-lives-in-nonisolated-heraldapi-target]].

## Key flows

1. **Listing conversations** → `HQBaseAPIClient.listConversations(mailboxID:cursor:limit:)` → calls generated OpenAPI client → AuthenticatingMiddleware attaches token → returns ConversationPage (Sendable DTO).
2. **Token refresh** → SyncEngine hits a 401 → AuthenticatingMiddleware calls `refreshIfNeeded()` → AccountTokenProvider updates Keychain → retry succeeds.
3. **Offline** → URLSession throws `.urlErrorNotConnectedToInternet` → wrapped as `.offline` → views show offline banner → sync retries on reconnect.

## When you touch this

- Adding a new API endpoint? Update the vendored HQBase OpenAPI spec (`HeraldAPI/openapi.yaml`), run swift-openapi-generator, and add a method to HQBaseAPIClient that wraps the generated code.
- Changing error handling? Edit AuthenticatingMiddleware.intercept() and MailAPIError; check that all error paths in SyncEngine and OutboxService handle the new variant.
- Debugging a 5xx from HQBase? Check HQBase logs; Herald logs the URL and status at logger.error level in AuthenticatingMiddleware.
