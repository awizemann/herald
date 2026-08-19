---
created: 2026-08-19
updated: 2026-08-19
source_sha: 35ba57be0606d427a5aa36e1500b7f685b444351
source_paths: HeraldKit, Herald
source_paths_inferred: false
---

# Architecture Overview

Herald is a three-layer system: a Swift Package (`HeraldKit`) containing all logic, a SwiftUI app (`Herald`) for the UI, and a SwiftData cache that can always be rebuilt from the server.

## Layers

### HeraldKit — The logic layer

`HeraldKit` is an SPM package (`HeraldKit/Sources/HeraldKit`) containing:

- **Auth** (`HeraldKit/Sources/HeraldKit/Auth/`) — OAuth 2.1 PKCE, dynamic client registration, token refresh, and account storage in the Keychain via `KeychainAccountStore` (implements `AccountStore`).
- **API** (`HeraldKit/Sources/HeraldKit/API/`) — A generated OpenAPI client (`HeraldAPI` target) wrapped behind the `MailAPIClient` protocol, plus middleware for bearer-token auth and error handling.
- **Sync** (`HeraldKit/Sources/HeraldKit/Sync/`) — A delta-sync engine (`SyncEngine`) that reads the server's versioned mailbox, conversation, and message deltas and writes them to a local SwiftData store (`MailStore`). The store is a rebuildable cache; the server is the system of record.
- **Compose** (`HeraldKit/Sources/HeraldKit/Compose/`) — Draft lifecycle, attachments, and an outbox service (`OutboxService`) that queues and sends messages.
- **Notifications** (`HeraldKit/Sources/HeraldKit/Notifications/`) — New-mail detection and a notifier that posts macOS notifications.

Everything HeraldKit hands to the app is a Sendable value type (struct/enum) or a `nonisolated` protocol; the stateful pieces (`MailStore`, `SyncEngine`, `OutboxService`, `HQBaseAPIClient`) are actors. Views in Herald never touch a SwiftData `@Model` directly; they receive Sendable DTOs instead. See the architecture note.

### Herald — The app

`Herald/` (`Herald/App/`, `Herald/Views/`, `Herald/Compose/`) is a SwiftUI app with:

- **App coordination** (`Herald/App/AppEnvironment.swift:55`) — The `AppEnvironment` class orchestrates per-account graphs (`AccountGraph`, one per signed-in account), manages the sync engine and outbox, and holds the window state.
- **Views** (`Herald/Views/`) — Three-pane split view: mailbox list (left), conversation list (middle), message detail (right). Threaded readers, search, keyboard shortcuts.
- **Compose** (`Herald/Compose/`, `Herald/Compose/ComposeViewModel.swift:16`) — A separate window for drafting, with attachment support and reply/forward prefill.

### SwiftData cache

The SwiftData store is a rebuildable cache, not the system of record. SwiftData types are in `HeraldKit/Sources/HeraldKit/Sync/CachedModels.swift` (e.g., `CachedMailbox` at line 19, `CachedMessage` at line 124, `CachedDraft` at line 196). On launch, the sync engine reads the server's delta-sync cursor, fetches changes, and merges them into the store. If the store is corrupted or incompatible, delete it; the sync engine will rebuild it from scratch.

## Concurrency model

Herald uses Swift 6 strict concurrency with `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`:

- The main thread runs the UI and all view updates.
- Actors (`MailStore`, `SyncEngine`, `OutboxService`, `NewMailNotifier`, `AccountTokenProvider`) execute background work and communicate via async/await.
- All public types in HeraldKit are Sendable to enforce thread-safe crossing of the view/logic boundary.
- Anything an actor must call synchronously is `nonisolated`.

## Data flow

1. **Sign in** — User authorizes via OAuth. `AuthCoordinator` (`HeraldKit/Sources/HeraldKit/Auth/AuthCoordinator.swift:11`) launches a web session, exchanges the code for tokens, and stores them in the Keychain.
2. **Sync** — On login, `SyncEngine` reads the server's delta-sync cursor and fetches changes. It writes to `MailStore`, which notifies observers of new conversations, messages, and changes.
3. **UI** — `MailViewModel` (`@Observable`, main actor) pulls Sendable DTOs from `MailStore` after each sync and drives the views.
4. **Compose** — User drafts a message; `ComposeViewModel` manages attachments and prefill. On send, `OutboxService` queues the message and transmits it to the server.
5. **Notifications** — `NewMailNotifier` watches for new messages and posts system notifications.

## Key design decisions

- **One protocol, many implementations** — `MailAPIClient`, `AccountStore`, `Outboxing`, etc. are protocols so tests can inject fakes.
- **Strict Sendable boundary** — Views never touch `@Model`; all data crosses the boundary as frozen Sendable DTOs.
- **Delta sync** — After a bootstrap listing, Herald polls `GET /api/v1/changes` with a stored cursor and merges only what changed.
- **Cache-first** — The cache is always available for instant launch; sync is a background task.
- **Privacy-first analytics** — optional, opt-out usage counts via swift-stats; no mail content, addresses, or typed text ever leaves the machine (`Herald/Analytics/UsageEvent.swift` is the contract).

See Herald Architecture for more detail.

---
_Last updated: 2026-08-19 — architecture overview; fact-checked against the code for v0.3.0_