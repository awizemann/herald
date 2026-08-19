---
created: 2026-08-19
updated: 2026-08-19
source_sha: 35ba57be0606d427a5aa36e1500b7f685b444351
source_paths: HeraldKit/Sources/HeraldKit/API, HeraldKit/Sources/HeraldAPI
source_paths_inferred: false
---

# API Client and Network

Herald talks to HQBase via the **Mail API v1** (`/api/v1`). The client is generated from the OpenAPI spec using `swift-openapi-generator` and wrapped in a protocol for testability.

## Generated client

`HeraldAPI` is an SPM target containing the auto-generated OpenAPI types and client for the vendored HQBase Mail API v1 spec. It is built WITHOUT `SWIFT_DEFAULT_ACTOR_ISOLATION` so the generated code runs in the `nonisolated` context. See the decision note.

The generated client is never called directly from the app; instead, it is wrapped by `HeraldKit`.

## MailAPIClient protocol

`MailAPIClient` (protocol at `HeraldKit/Sources/HeraldKit/API/MailAPIClient.swift:35`) abstracts the HQBase API with methods for:

- Fetching mailboxes, conversations, messages, and message bodies
- Actions: read/unread, star, archive, trash, delete
- Drafts: create, update, delete
- Sending messages
- Searching

All methods are `async throws` and return Sendable value types.

## HQBaseAPIClient

`HQBaseAPIClient` (`HeraldKit/Sources/HeraldKit/API/HQBaseAPIClient.swift:11`) is an actor that implements `MailAPIClient`. It:

- Uses the generated OpenAPI client internally
- Wraps methods in error handling (transforms low-level HTTP errors into `MailAPIError`)
- Applies middleware for authentication and retry logic

## Middleware and error handling

`AuthenticatingMiddleware` (`HeraldKit/Sources/HeraldKit/API/AuthenticatingMiddleware.swift:14`) adds bearer-token auth to every request and handles 401 by refreshing the token and retrying.

`MailAPIError` (`HeraldKit/Sources/HeraldKit/API/MailAPIError.swift:7`) is the public error type, covering:

- Transport failures (network down, invalid response)
- Server errors (4xx, 5xx)
- Decoding failures
- OAuth token issues

Every error is logged (debug, warning, or error depending on severity).

## API contract

The HQBase Mail API v1 supports:

- **Mailboxes** — GET list (bare array)
- **Messages** — GET with filters (folder, mailbox, search); pagination support (pending upstream)
- **Message bodies** — GET HTML and inline attachments separately (remote images blocked until user trusts sender)
- **Drafts** — Create, update, delete
- **Actions** — Bulk mark read/unread, star, archive, trash, delete

---
_Last updated: 2026-08-19 — API client and network; fact-checked against the code for v0.3.0_