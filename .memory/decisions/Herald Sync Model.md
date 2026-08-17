---
title: Herald Sync Model
type: note
permalink: hqbase-mac/decisions/herald-sync-model
tags:
- decision
- swiftdata
- sync
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
