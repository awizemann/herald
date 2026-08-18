---
title: Herald Sync Model
type: note
permalink: hqbase-mac/decisions/herald-sync-model
tags:
- decision
- swiftdata
- sync
created: 2026-08-16
updated: 2026-08-16
---

## Observations
- [decision] The SwiftData store is a REBUILDABLE CACHE, not the system of record — the HQBase server is. Recovery on incompatible/corrupt store = delete and re-sync. NO VersionedSchema / SchemaMigrationPlan; store lives in Application Support and may be nuked at will (why: §4 says pick one on day one; server holds truth, so migrations buy nothing and cost risk) #store-role
- [decision] Sync = polling, because the server has no delta endpoint and no APNs: conversations paged via /conversations (limit 100 + cursor); messages re-listed per (mailbox, folder); diff by id + state timestamps (readAt/starredAt/folder) and only changed rows written (why: web app polls 10s; unchanged rows must not trigger view invalidation) #polling
- [decision] Cadence: 15s while a window is key, refresh immediately on app activation and after any local mutation, back off to 60s when idle/no window; never Task.sleep on main as a wait — the engine is an actor with its own loop and publishes changes over an AsyncStream the view-model consumes #cadence
- [decision] Optimistic local mutations: actions (read/star/archive/trash) update the store immediately, POST in the background, and revert on failure with a logged error (why: mail triage must feel instant) #optimistic
- [todo] When upstream ships pagination + updatedSince on /messages, replace re-list with cursor delta; keep the diff layer so the change is contained to SyncEngine #upstream

## Relations
- relates_to [[Herald Architecture]]
- relates_to [[HQBase Mail API v1 Contract]]

## Update (2026-08-15 — P0.3 implementation facts)
- [gotcha] Interruptible cadence timer must wrap `Task.sleep` in do/catch-and-return, NEVER `try?` — on cancellation `try?` swallows and execution falls through to the wake signal, latching it, and the engine polls the server flat out (22 passes in 0.24s in tests). The refreshNow()-driven test caught it; a timing test would not have #timer
- [decision] `CachedConversation` is keyed by (account, thread, listFolder, mailboxKey) — a thread appears under both inbox and archived and deleteMissing must drop one scope only; `mailboxKey` = `mailboxID ?? ""` because optional equality in #Predicate/#Index is unreliable in SwiftData #keys
- [decision] Tombstoning is a hard delete (rebuildable cache); when the 20-page conversation cap is hit, tombstoning is SKIPPED for that folder with a warning — never delete rows from pages never fetched #tombstone
- [fact] Sync scope default = inbox/sent/archived/trash; `.complete` adds drafts/catchall; store bodies live in `CachedMessageBody` sidecar so the hot summary row stays lean #scope

## Update (2026-08-15 — audit facts)
- [fact] SwiftData LIGHTWEIGHT-MIGRATES a store written by a different Schema in place (entities removed → "Persistent History has to be truncated"), so `MailStoreContainer.make(url:)`'s delete-and-rebuild path only runs for genuinely unopenable files; the foreign-schema test asserts "usable + no foreign rows", the corrupt-file test asserts file replacement (by sentinel bytes — inodes get reused) #recovery
- [gotcha] MailStore lookups MUST be account-scoped (body sidecar, message(id:), local actions) — the #Unique is (accountID, messageID) and two HQBase instances reuse ids; fixed in P0.6 with a two-account test #accounts
- [gotcha] A running actor method pins the actor: replacing `AppEnvironment.syncEngine` without `await stop()` leaks the loop forever (unbounded event stream buffers with no consumer) — activate() now stops the old graph first #lifecycle
- [todo] Optimistic action vs concurrent sync pass has no fence (a pass mid-POST can snap the row back until the next poll) — follow-up: pending-mutation set in MailStore respected by upserts #followup

## Update (2026-08-18 — journal mode)
- [decision] SyncEngine has two modes chosen per pass by feature detection: JOURNAL (server has /changes: checkpoint → paginated bootstrap per mailbox+folder → conversations → consume changes; steady state = re-list mailboxes (purge vanished, bootstrap new BEFORE the journal) → page /changes to hasMore=false persisting the cursor AFTER EACH applied page → re-list conversations only for touched (mailbox, conversation-folder) scopes, always incl. starred; 410 → clear checkpoint + re-bootstrap) and LEGACY (today's re-list; page-walks fully once a Link/cursor has ever been seen for the account, else the 100-cap guard applies). A 404 from /changes marks the account legacy for the engine's lifetime (re-probed on next activation) #journal
- [fact] `CachedSyncCheckpoint` @Model (accountID unique: changeCursor, bootstrappedAt) lives in the rebuildable cache — nuking the cache forces a clean re-bootstrap by design; message page-walks are capped at 50 pages (skip tombstoning + warn when hit) #checkpoint
- [gotcha] Tombstoning a message cannot fix conversation rows (denormalized per listing scope) — journal mode must re-list touched scopes; nothing but the starred scope reveals a star change #derived
- [decision] Journal-sync hardening (audit of c78f421, fixed in bf7d2e1): MailStore keeps a PENDING-MUTATION fence per (account, message) — journal upserts never overwrite readAt/starredAt/folder while a local action is in flight; on POST success the server's returned summary is applied as authoritative and the fence dropped; revert happens only if the row still equals the optimistic snapshot. Conversation scopes are refreshed PER PAGE before that page's cursor is persisted; a folder move refreshes old AND new scopes; a new mailbox's row is written only after its listing succeeds; `stopAndWait()` + pass-generation guard mean no store writes after stop; a cursored 404 on /changes is a pass failure (only the cursor-less probe flips to legacy); pages apply in journal order; the bootstrap checkpoint is persisted before catch-up #hardening
- [gotcha] The journal removes re-listing's 15s self-healing — every "cursor advanced but derived state not updated" path becomes a durable divergence; treat cursor-persist as a transaction boundary #atomicity

## Update (2026-08-18 — v0.2.0 shipped; issue fixes)
- [fact] CORRECTION: `MailStore.applyLocalAction` for archive/trash now MATERIALISES the destination conversation-scope row (`materializeMovedScope`) and records it in `LocalActionUndo.insertedConversations` for revert — the earlier fact "only the message folder changes; the VM filters by latest.folder" is now half true (the filter remains as a belt) #materialize
- [rule] Programmatic selection advances (after archive/trash) NEVER drill (`select(_:drill:)` / `drillsOnSelection` flag); only user selection drills. Refresh sets `reloadsWhenPassFinishes` → `.finished` reloads the presented scope + counts #selection
- [fact] Trash scope: conversation-level archive/trash are server no-ops (`affected: 0`), and there is NO restore action in v1 → Herald offers per-message "Move to Archive" (`MailActionService.perform(_:onMessagesOfThread:)`) and never sends the no-op conversation actions; `affected == 0` reverts the optimistic move immediately. Upstream HQBase/hqbase#42 asks for `restore` #trash
