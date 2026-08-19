---
created: 2026-08-19
updated: 2026-08-19
source_sha: 35ba57be0606d427a5aa36e1500b7f685b444351
source_paths: HeraldKit/Sources/HeraldKit/Sync
source_paths_inferred: false
---

# Sync and Storage

Herald uses SwiftData for a local cache that is rebuilt on-demand from the HQBase server. The sync engine (`SyncEngine`) fetches delta-sync updates, merges them into the cache, and observers subscribe to changes.

## The cache is rebuildable

The SwiftData store is a rebuildable cache, not the system of record. The server is authoritative. On a clean install, the cache is empty; the sync engine populates it. If the cache is corrupted or an app update is incompatible, delete the SwiftData file; the sync engine will rebuild it on the next launch.

No `VersionedSchema` or `SchemaMigrationPlan` — the schema is bare `Schema([...])`. Recovery = delete + re-sync.

## Cached models

`HeraldKit/Sources/HeraldKit/Sync/CachedModels.swift` defines the SwiftData `@Model` types:

- `CachedMailbox` (line 19) — A mailbox (Inbox, Sent, etc.) with id, name, unread count, and sync cursor.
- `CachedConversation` (line 65) — A conversation thread with id, subject, participants, and a list of message ids.
- `CachedMessage` (line 124) — A single message: id, timestamp, sender, recipients, direction, attachments, and flags (unread, starred).
- `CachedMessageBody` (line 164) — The rendered HTML body of a message (fetched on-demand, cached separately).
- `CachedDraft` (line 196) — A draft message under composition.
- `CachedSyncCheckpoint` (line 237) — The server's opaque sync cursor and per-mailbox checkpoints for delta-sync.

All are `@Model` but treated as internal implementation; views never touch them. Instead, views see Sendable DTOs (e.g., `ConversationSummary`, `MessageSummary`) that `MailStore` projects from the models.

## The sync engine

`SyncEngine` is an actor that:

1. Reads the server's sync checkpoint.
2. Fetches delta changes (new/updated/deleted messages and conversations).
3. Merges them into `MailStore`.
4. Reports what changed (`ChangeSet`) so the view model and `NewMailNotifier` can react.

The sync checkpoint is opaque; Herald stores it as-is and sends it back on the next sync request. The server dictates the sync semantics.

## MailStore — the transaction boundary

`MailStore` is an actor wrapping SwiftData. It:

- Owns the SwiftData `ModelContext`
- Writes cached models atomically (one transaction per sync batch)
- Projects Sendable DTOs for views to observe

`MailViewModel` (the app's `@Observable` main-actor model) asks `MailStore` for fresh DTOs after each sync cycle; views observe the view model, never the store.

## Delta-sync protocol

HQBase ≥ 1.1.0 exposes paginated `GET /api/v1/messages` (RFC 8288 `Link: rel="next"`) and a journal-backed `GET /api/v1/changes` endpoint. Herald's cycle: re-list `/mailboxes`, bootstrap a new mailbox by taking a changes checkpoint and paging the full message list, then poll `/changes` with the stored cursor and apply upserts and delete tombstones. Drafts are the exception — `GET /drafts` is a whole-list read, so the Drafts folder is re-polled rather than delta-synced. The approved contract is recorded in `.memory/roadmap/Upstream Delta Sync Contract (approved).md`.

---
_Last updated: 2026-08-19 — sync and storage; fact-checked against the code for v0.3.0_