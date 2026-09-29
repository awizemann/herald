---
created: 2026-09-29
updated: 2026-09-29
source_sha: 2bfa6bee79e5baf669c80ee8cf23b74d74feaead
source_paths: HeraldKit/Sources/HeraldKit/Sync
source_paths_inferred: false
---

# Sync Engine

The sync engine is Herald's heartbeat: it polls the HQBase server for changes, applies them to the local SwiftData cache, and broadcasts updates to the UI. The cache is a **rebuildable, non-authoritative copy** — the server is always the source of truth. If the cache corrupts or drifts, you delete and resync.

## Architecture

**CachedModels** (`CachedModels.swift`)
- `CachedMailbox`, `CachedConversation`, `CachedMessage`, `CachedDraft`, `CachedLabel` are SwiftData @Model classes (nonisolated, ReferencesOnly foreign keys).
- `SyncCheckpoint` and `MessageDeletion` are value types tracking sync state.
- All are bare schema: no `VersionedSchema` or migration plans. Recovery = delete + re-sync.

**ChangeSet** (`ChangeSet.swift`)
- A Sendable struct describing what the server told you changed: added/modified/deleted mailboxes, conversations, messages, labels.
- Produced by delta-sync polling and applied atomically to the cache in `SyncEngine`.

**SyncEngine** (actor, protocol `MailSyncing`)
- Polls `/api/v1/changes` at configurable intervals (active 15s, idle 60s by default).
- Applies ChangeSets to the SwiftData context; broadcasts via `@Published` properties so views re-render.
- Integrates with the wake socket (`setWakeSocketConnected`) to stretch polling intervals when the server has new mail alerts.
- See [[herald-wake-socket-architecture]] and [[herald-sync-model]] for the decisions.

## Key invariants

1. **Polling is the source of truth.** The wake socket accelerates polling but never replaces it — if the socket drops, polling keeps syncing.
2. **One active account at a time.** AppEnvironment switches sync engines per account; only the frontmost account's engine polls.
3. **Paging prevents memory bloat.** Mailbox listings page at 100 messages per fetch.
4. **Label membership is a separate cadence.** Labels sweep at 120s, not on every message poll — see [[herald-label-caching-and-ui-architecture]].

## When you touch this

- Adding a new sync'd entity? Add a Cached* @Model class, update ChangeSet union, and wire it through SyncEngine.apply().
- Changing polling intervals? See `SyncEngine.defaultActiveInterval` etc.; test offline/online transitions in HeraldTests/OfflineTests.
- Debugging stale data? Check git log for the last resync (SwiftData deletes leave no trail); add `.detail` logging to ChangeSet.apply().
