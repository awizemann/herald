---
title: Herald Sync Model
type: note
permalink: hqbase-mac/decisions/herald-sync-model
tags: [decision, swiftdata, sync]
created: 2026-08-16
updated: 2026-09-19
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
- relates_to [[Herald Label Caching and UI Architecture]]
- relates_to [[Herald Wake Socket Architecture]]

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


## Update (2026-09-04 — attachment metadata in the cache, P3)
- [fact] `CachedMessageBody` now carries `attachments: [Attachment]` (a Codable blob beside the body, metadata only — never bytes) so the attachment bar renders offline; the schema change is additive on the rebuildable cache, still bare `Schema([...])` with NO VersionedSchema/migration plan #attachments
- [gotcha] A Codable value array on a @Model is an opaque blob: adding a NON-OPTIONAL field to `Attachment` (as `disposition` was) invalidates every previously written blob with no migration hook. Acceptable only because the store is rebuildable — if `Attachment` gains another required field, treat it as a cache-nuke, not a migration #blob
- [decision] `storeBody(..., attachments:)` treats an EMPTY list as "this write knew nothing about attachments" (the plain-text path) and never clears metadata a previous detail fetch cached #merge


## Update (2026-09-04 — labels, P8)

- [fact] There are now THREE poll cadences in one pass, in order: messages (15s active / 60s idle, journal-driven), drafts (60s, whole-list diff), labels (120s, per-label sweep). Each later surface has its own failure mode and can never fail the mail pass; each advances its own "last polled" stamp only on success #cadence
- [fact] Labels are the second surface with NO usable delta. The v1 change journal DOES report a label-only edit (upstream bumps `messages.updated_at`), but the v1 upsert payload has no `labels` field, so the entry proves a change and identifies nothing — membership is re-derived by listing each label. `refreshLabelsNow()` forces it, the way `refreshDraftsNow()` forces the drafts read #labels
- [gotcha] The per-label listing is authoritative for that label ONLY when the page-walk reached the end; a capped walk writes nothing at all, same rule as message tombstoning. See [[Herald Label Caching and UI Architecture]] #labels


## Update (2026-09-04 — P6: wake socket, and the 100-cap guard reconciled against a live 1.3.4 server)

- [fact] CORRECTION to the `#cap` guard (recorded 2026-08-16 against a 1.1.2 server, when `GET /messages` silently clamped to 100 rows with no pagination): upstream 1.3.4 DOES paginate, verified live — `GET /messages?limit=2` returns `Link: <…cursor=…>; rel="next"`. The guard is NOT retired, and deliberately so: it is now the LEGACY-SERVER path. `paginatingAccounts` flips the moment any `Link` is seen for an account, and from then on a full-cap page is page-walked normally; the "a 100-row response may be truncated, skip tombstoning" rule only ever applies to a server that never emitted a cursor. Deleting it would break pre-1.3 servers by erasing unreturned mail on every pass #cap-status
- [done] t-8a1c0051's live verification is SATISFIED: checkpoint → mutation → single upsert entry → `hasMore:false` exercised end to end against localhost:8787, and the pagination the guard keys on confirmed present. See the "#changes-live" facts in [[HQBase Mail API v1 Contract]] #journal-verified
- [gotcha] The journal's cursor rejection is a 400, not a 410 (the server reserves 410 for a retention policy it has not built). Herald persists the cursor, so before P6 a foreign cursor — journal rebuilt, or a cache carried to a different instance — was PERMANENT: every pass failed on it and no amount of retrying could clear it. `AuthenticatingMiddleware` now maps both statuses to `.cursorExpired`, which drops the checkpoint and re-bootstraps (self-healing, because bootstrap asks the server for a fresh cursor) #cursor-rejection
- [decision] There are now FOUR wake sources, and polling is still the floor: the `GET /events` socket stretches the message poll (active 15s→120s, idle 60s→300s) while it is CONNECTED and restores it the instant it is not — never stops it. The frames are documented wake-only with no replay, so a client that stopped polling would diverge silently the first time one was dropped; the stretched interval is also what still carries the drafts (60s) and label (120s) sweeps, which only ever run inside a pass. See [[Herald Wake Socket Architecture]] #poll-stretch


## Update (2026-09-04 — A1 cache integrity: blob decoding, tombstone cascade)

- [gotcha] MEASURED CORRECTION to the `#blob` note above ("treat it as a cache-nuke"): there is nothing to nuke, because nothing gets control. SwiftData decodes a `Codable` column with `try!` (`SwiftData/DefaultStore.swift:2393`) — a blob whose shape no longer matches the DTO is a PROCESS-FATAL trap inside `fetch`, not a thrown error. Verified both ways in-process: a missing key faults with `DecodingError.keyNotFound`, non-JSON bytes fault with `dataCorrupted`. So no typed error, no catch, and no route to `MailStoreContainer`'s delete-and-retry valve exists — that valve guards `open()` only, and the file here opens perfectly #try-bang
- [decision] The fix is therefore STRUCTURAL, not a recovery path: every cache-blob DTO (`Attachment`, `DraftAttachment`, `MailboxAddress`, `SignatureSnapshot`) now has a TOTAL `init(from:)` — explicit `CodingKeys`, every field decoded with a fallback — so a missing, renamed or retyped key degrades ONE cached value instead of crashing the app on every launch. Safe precisely because the store is a rebuildable cache: the next fetch corrects the defaulted field. Their `Codable` conformance is used by SwiftData ONLY (the API layer maps from generated OpenAPI types), so nothing else loses its error reporting #total-decode
- [rule] CACHE-BLOB CONVENTION: a new field on one of those four DTOs goes in THREE places — the property, `CodingKeys`, and the decode — and must have a sensible default. Hand-written `CodingKeys` mean an omitted field silently stops persisting, which is what the round-trip test in `CacheIntegrityTests` exists to catch #convention
- [fact] Residual, accepted: byte-level corruption of a blob column (bit rot, a half-written page) still faults before any Herald code runs. Fatal on any design short of storing the column as `Data` and decoding by hand; SQLite's own integrity guarantees make it far rarer than the shape change, which was one routine schema edit away #residual
- [fact] `deleteMissingMessages` now cascades like `deleteMessage`: body sidecar, label assignments and the pending-mutation fence. Every orphan it used to leave was DURABLE — an assignment keeps a dead message in its label's listing forever (the sweep only replaces the set of a label it re-reads), a sidecar becomes unreachable, and a fence blocks the journal from ever writing that id again #cascade
- [fact] ACCEPTED and now commented in `replaceAssignments`: the per-label sweep inserts assignment rows for messages the cache has never held (the label listing covers the whole account; the message cache covers only synced folders). Consequence — a label's assignment-row count can exceed what the by-label conversation listing resolves, so any badge must count what the listing RESOLVES, never `CachedLabelAssignment` rows #sweep-unknown-ids


## Update (2026-09-19 — U2: label membership comes from ROWS; the sweep is a reconciliation)

Upstream 1.4.2's `includeLabels=true` embeds `labels` on every `MessageSummary`,
so the "labels have no delta" premise of the 2026-09-04 `#labels` fact above is
now HALF WRONG — it holds only for servers below 1.4.2, which remain supported.

- [decision] There are still THREE poll cadences in one pass (messages 15s/60s,
  drafts 60s, labels), but the LABEL one now has two regimes chosen per account:
  `defaultReconciliationLabelPollInterval` 1800s once the server is known to embed
  labels, and the legacy `defaultLabelPollInterval` 120s / `defaultIdleLabelPollInterval`
  750s pair (with the visible/idle surface signal) when it is not. The
  visible/idle signal is IGNORED in the embedding regime #cadence
- [decision] CORRECTION to the 2026-09-04 `#labels` fact: the v1 journal upsert
  NOW identifies membership. `MailStore.applyMessageUpserts` — the single funnel
  every stored summary passes through (journal, listings, triage-action answers) —
  writes each summary's embedded labels via `applyEmbeddedLabels(from:accountID:)`.
  `MailViewModel` does the same for the two routes the VIEW fetches and never
  stores (single-message detail, thread). `refreshLabelsNow()` is unchanged #labels
- [constraint] `MessageSummary.labels` is `[MailLabel]?` and the distinction is
  load-bearing at the STORE: `nil` = "the row said nothing" (old server, or nobody
  asked) and is SKIPPED; `[]` = "no labels" and DOES clear. A `?? []` on this path
  wipes every chip in the workspace on the first pass against a 1.3.4/1.4.0 server.
  The embedded write is per-MESSAGE and can never truncate a label's wider
  membership — only `replaceAssignments` (a completed sweep) may do that #labels
- [decision] CAPABILITY DETECTION is by RESPONSE SHAPE, per account, per session,
  never by version (`info.version` is the API version; no capability endpoint
  exists): `SyncEngine.labelEmbeddingAccounts` records an account the moment any
  summary arrives with non-`nil` labels. `[]` counts as proof; `nil` is never
  evidence of anything, so an undetected account simply keeps the legacy sweep —
  the conservative direction (more requests, never a wrong cache). Cleared by
  `start()`, because a server can be upgraded or rolled back between engines #labels
- [gotcha] A label-only edit bumps `messages.updated_at`, so it arrives as a
  journal upsert whose every message FIELD is identical — the `ChangeSet` is empty
  and `.changed` is never emitted, while the chips on screen are now wrong.
  `MessageUpsertResult.labelsChanged` exists for exactly that; the engine drains it
  into ONE `.labelsChanged` per pass #labels
- [fact] VERIFIED LIVE 2026-09-19 against the local 1.4.2 instance (owner cookie
  session on the Mail API): assigning a label produced exactly ONE journal upsert;
  `GET /changes?cursor=…&includeLabels=true` carried the full `labels` array on it,
  removing the label produced an upsert carrying `[]`, and the same call WITHOUT
  the parameter had no `labels` key at all. U0 had already verified the 1.4.0
  instance ignores `includeLabels` and answers without the key #labels
- [fact] The reconciliation sweep is NOT retired and must not be: a label deleted
  workspace-wide touches no message, so no row ever mentions it again; and the
  sweep stores assignments for messages in folders this cache has never listed,
  which rows can never supply. It also runs in full on the `labels` wake frame and
  whenever the label LIST changes (which drops the sweep digests). The `messages`
  wake frame deliberately still does NOT force it #labels



## Update (2026-09-19 — F1: the label fence and the pass's label event; commit 1d3a614)

Two consequences of U2's "membership comes from ROWS", found by the U6 audit.

- [gotcha] `runPass` drained `passLabelsChanged` into `.labelsChanged` only on
  the SUCCESS path. A journal cycle is several pages, each applied and
  checkpointed on its own, so "page 1 wrote labels, page 2 threw" is ordinary —
  and page 1's membership is durable. The event is now drained on EVERY exit (a
  `defer`, plus an explicit call before each `.failed` so the order is
  chips-then-banner). Safe unconditionally: the event has no payload and the
  view-model answers it with one idempotent index reload #labels
- [decision] The pending-mutation fence now has a LABEL half. The 2026-08-18
  `#hardening` fence pins a MESSAGE and three of its fields; the label fence
  pins the pair `(message, labelID)`, because a message carries several labels
  and pinning the row would freeze the ones the action never touched. While a
  pair is pinned, an embedded write (`applyEmbeddedLabels` — per-message
  AUTHORITATIVE, which is what made a stale page dangerous) and the
  reconciliation sweep both leave it exactly as the cache has it; the action's
  own settle is exempt. Released on settle, on a settle that threw, and on
  rejection-after-revert, and cascaded by every delete path — a leaked pin
  fences the pair against the server for the whole session. Full design in
  [[Herald Label Caching and UI Architecture]] #hardening
- [fact] `SyncEngine.swift` is split: `SyncEngine+Labels.swift` and
  `SyncEngine+Drafts.swift` hold those two surfaces (996 lines left in the main
  file). Stored properties stay on the actor — extensions cannot declare storage
  — so the per-session capability sets (`labellessAccounts`,
  `labelEmbeddingAccounts`, `lastSweepDigests`, `draftlessAccounts`) are still
  declared there, with their reasoning moved next to the code that writes them #split
