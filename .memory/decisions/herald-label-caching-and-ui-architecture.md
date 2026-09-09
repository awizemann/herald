---
title: Herald Label Caching and UI Architecture
type: note
permalink: hqbase-mac/decisions/herald-label-caching-and-ui-architecture
tags: [labels, sync, swiftdata, ui]
source_paths: [HeraldKit/Sources/HeraldKit/Sync/MailStore+Labels.swift, HeraldKit/Sources/HeraldKit/Sync/SyncEngine.swift, HeraldKit/Sources/HeraldKit/Sync/CachedModels.swift, HeraldKit/Sources/HeraldKit/Sync/MailActionService.swift, HeraldKit/Sources/HeraldKit/Model/MailLabel.swift, Herald/App/MailViewModel+Labels.swift, Herald/Design/LabelChip.swift, Herald/Views/SidebarView.swift]
source_paths_inferred: false
source_sha: 3d99c49fde000552ed08dab90a1d54a86d74cb0b
created: 2026-09-04
updated: 2026-09-04
---

P8 (task t-75e2f028), 2026-09-04. Labels shipped against the v1 API, whose message/conversation/change payloads carry no `labels` field (see the contract note) — so everything here follows from "membership has to be derived client-side".

## Observations
- [decision] Label MEMBERSHIP is derived by a per-label sweep of `GET /messages?labelId=` on its own 120s cadence (SyncEngine.defaultLabelPollInterval), NOT from /changes: the v1 journal reports a label-only edit as a message upsert, but its payload has no `labels`, so the journal can say that something changed and never what the labels now are #sync
- [decision] Assignments are cached as a JOIN model `CachedLabelAssignment(accountID,labelID,messageID,threadID)` with `threadID` DENORMALIZED, so row chips and the by-label listing are one indexed fetch rather than a join per row; the sweep must be able to replace ONE label's whole set, which a `[String]` column on CachedMessage could not do #cache
- [gotcha] `replaceAssignments` is AUTHORITATIVE by construction, so a membership page-walk that hit the page cap (or the pre-pagination 100-row cap) returns nil and writes NOTHING — applying a truncated listing would erase every assignment the server had not got round to returning, the same trap message tombstoning guards #sync
- [decision] The sidebar's label item is `SidebarItem.label(id)`, a THIRD listing mode beside folder and drafts: a label spans every folder at once, so `ConversationFolder` cannot express it, and `refilter()` skips both the folder presentation rule and the server-search union while one is selected #ui
- [gotcha] The label index is loaded BEFORE the conversation rows are published (MailViewModel.reloadConversations), because macOS List caches a measured height per row identity — a row that first renders without its chips and grows a line afterwards stays clipped, the same trap the mailbox chip has #rows

## Relations
- relates_to [[HQBase Mail API v1 Contract]]
- relates_to [[Herald Sync Model]]
- relates_to [[Herald Design System and Accessibility]]


## Further decisions and deferrals (P8)

- **Optimistic writes.** The list-row menu labels the whole THREAD (`MailActionService.setLabel(_:onConversation:)`); the reading pane's tag menu labels the ONE MESSAGE it is showing — the control matches the chips beside it. Both write the cache first and revert EXACTLY the rows the optimistic write changed (`LabelActionUndo` carries only the rows that actually moved, so a revert never removes a label the action did not add). On success the server's `LabelAssignmentResult.labels` replaces the message's set, which is how a label assigned elsewhere since the last sweep arrives for free.
- **A conversation `affected: 0` is NOT reverted**, unlike the triage actions: upstream returns 0 when every accessible copy was already in the requested state, which agrees with the optimistic write.
- **Colours.** `LabelColor` re-parses the server's raw string with a `.gray` fallback rather than decoding strictly, so an instance that adds an eleventh colour still draws its labels. `MailTheme.labelTint(for:)` is a translation table onto `NSColor.system*` (amber→systemYellow, gray→systemGray) — unlike `mailboxPalette` its ORDER is not a persistence contract, because the server owns the names.
- **Additive schema, no migration.** `CachedLabel` + `CachedLabelAssignment` were added to the bare `Schema([...])`; the store is a rebuildable cache, so an incompatible old store is deleted and re-synced (`MailStoreContainer`). Assignments are dropped alongside their message in `deleteMessage`/`purgeMailbox` and alongside their label in `replaceLabels`, since nothing else would ever clean them up.
- **A 404 on `GET /labels` disables the sweep for the session ONLY before the account has ever read its labels** (`labelCapableAccounts`), mirroring the `/changes` cursor-less-probe rule: a later 404 is a transient server fault and must not silently drop the feature.

### Deferred, deliberately
- **Draft labels.** `GET /api/v1/drafts` really does return them, but neither OpenAPI document declares `labels` on `Draft`, so the generated client cannot see the field — reading them needs a vendored-spec patch of the same family as `DraftFields`. `PUT/DELETE /drafts/{id}/labels/{labelId}` also needs the `mail:send` scope. Not cheap; not done.
- **Label CRUD** is impossible from the Mail API by design (owner/admin cookie session only) — Herald consumes labels, it can never create or rename one.
- **Analytics.** No `UsageViewKind` for a label listing and no label-change event: adding either means a new wire name and a new fixture id, which belongs with the rest of the vocabulary rather than smuggled in with a feature. `showLabel` still CONSUMES the pending navigation source so a sidebar click cannot leave a stale `via` behind.
- **Multi-label filtering** (the repeated `labelIds` AND filter) has no UI.


## Known limits (adversarial audit, 2026-09-04 — accepted, not fixed)

Fixed in the same pass: the conversation answer's union being written onto one message row (now `settleThreadLabel`, which settles only the toggled label per message); `revealConversation` not leaving a label listing; a per-label listing refusal disabling the whole feature; a partial sweep swallowing the changes that did land; the N+1 fetch inside the optimistic write; snapshot-stale toggle bindings; restore/put-back offered inside a label listing (it is a no-op unless the row is in the folder the request names, and a label listing crosses folders).

Left as known limits:
- [gotcha] `conversations(withLabel:)` materialises every cached conversation row for the account and filters in Swift — `#Predicate` cannot take a `Set.contains` over a captured collection of that shape, and the alternative is a fetch per thread. Fine for a personal cache, a scaling problem for a large one; batching by chunked thread ids is the fix when it bites #perf
- [gotcha] `labelIDsByThread` fetches the WHOLE assignment table for the account on every conversation reload (which is every sync pass that changed something, every folder switch, and each label toggle). Scoping it to the presented thread ids is the fix when it bites #perf
- [gotcha] A sweep that started before a local toggle finishes with PRE-toggle membership and `replaceAssignments` deletes the just-confirmed row — the chip disappears for up to one sweep (≤120s) and then heals. A "locally modified since" stamp compared against the sweep's start instant is the real fix #race
- [gotcha] The label listing can only show threads the CONVERSATION cache holds. Assignments are stored for every message the sweep sees, but a label legitimately spans mailboxes and folders Herald has never listed, so the listing silently under-reports #completeness
- [gotcha] An eleventh server colour fails the whole `GET /labels` decode (the vendored spec declares the enum closed). Consistent with the min-server-1.3.4 policy; `LabelAPITests.unknownColourHandling` asserts it so the failure names itself #decode


## Sweep cadence and index precompute (A3, task t-93791ab6, 2026-09-04)

The 2026-09-04 full-surface audit named the sweep the dominant idle cost: at 20 labels it is 20+ `GET /messages?labelId=` page-walks every 120s, forever, whatever the app is doing. Four changes, all in the "make it affordable", not "make it different", direction.

- [decision] **The sweep has TWO intervals, chosen by a visibility signal.** `SyncEngine.setLabelSurfaceVisible(_:)` mirrors `setWakeSocketConnected` — `defaultLabelPollInterval` (120s) while true, `defaultIdleLabelPollInterval` (750s = 12.5 min) while false — and the ctor clamps the idle one to `max(idle, visible)` so it can only ever be a floor on RARITY. Unlike the socket setter it does NOT wake the loop when it flips true: a wake costs a whole mail pass, and the two moments that genuinely need labels now (opening a listing, Refresh inside one) already call `refreshLabelsNow()`, which wakes AND forces #sync
- [decision] **The signal is `selectedLabelID != nil || (!labels.isEmpty && isAppActive)`**, recomputed in `MailViewModel.updateLabelSurfaceVisibility()` from four call sites (`reloadLabels`, `setActive`, `showLabel`, launch) and only pushed when it actually flips. Deliberately not finer: a "sidebar collapsed / list scrolled past its chips" signal is several pieces of view state racing one actor hop, for a cadence whose job is to be approximately right — and being wrong in the quiet direction shows stale chips with no tell. Backgrounded-with-labels and no-labels-at-all are the cases that matter and both are unambiguous #ui
- [decision] **A sweep whose row set matches the previous sweep's skips `replaceAssignments`** — `SweepDigest(count, Set(rows).hashValue)` per label, held in the engine. Order-independent (the server promises none) and count-carrying so a hash collision alone cannot suppress a write. Digests are dropped by `start()` (new account) and by `refreshLabelsNow()` (the escape hatch: the explicit path always does the full authoritative write), and pruned to the labels the server still lists. A page-capped walk records NO digest, or the next complete walk that happened to match would be swallowed #perf
- [gotcha] The digest INTERACTS WELL with the pre-existing "a sweep that started before a local toggle deletes the just-confirmed row" race: the stale sweep now matches the previous digest and skips, so the local row survives instead of flickering for up to one interval. It does not FIX the race — a sweep whose membership moved for other reasons still overwrites — but it narrows it #race
- [decision] **`MailStore.labelIndex(accountID:)` replaces `labelIDsByThread` as the view-model's read** and returns BOTH `idsByThread: [String: Set<String>]` and `threadCounts: [String: Int]` from one pass. Both walks use `propertiesToFetch` + `ModelContext.enumerate(batchSize: 500)` — nothing reads a property outside the fetched set, which is the condition for a partially-materialised model to stay cheap (reading an unfetched one faults the row in individually and turns the saving into an N+1) #perf
- [decision] **The badge counts RESOLVED threads, which the old `threadCount(forLabel:)` did not.** The A1 comment on `replaceAssignments` is explicit that a badge must count what the listing can resolve, never assignment rows — the sweep stores rows for messages in folders this cache has never synced. Counting distinct index thread ids was therefore INCONSISTENT with that note, and is now fixed by intersecting against the cached `CachedConversation` thread ids inside `labelIndex`. Test `badgeCountsResolvedThreads` asserts badge == listing count #cache
- [decision] **`conversations(withLabel:)` filters thread ids in the STORE**, in chunks of 500 (SQLite's ~999 bound-parameter ceiling). A captured `Array.contains` DOES compile inside `#Predicate` — the earlier "impossible" note was about `Set.contains`. Each chunk is store-sorted newest-first and stops after `limit` DISTINCT threads (correct because the global top-`limit` is a subset of the union of each chunk's top-`limit`); a multi-chunk result is re-sorted by `sortDate` before the cap, since chunks are only individually ordered #perf
- [decision] **A label write reloads the index exactly once.** `setLabel` used to call `reloadLabelIndex()` AND then `reloadConversations()` inside a listing — two whole-account index reads per toggle, because `reloadConversations` rebuilds the index itself before publishing rows. Now the same either/or `applyLabelsChanged` makes, factored into `reloadIndexAfterLabelChange()`. `labelIndexReloadCount` is the instrumentation seam #ui

### Residual risks accepted
- The digest can only be wrong if the store diverges from the server AND the server's membership then never changes again. `refreshLabelsNow()` (opening the label, Refresh inside it) is the recovery and it is on the path a user takes the moment they notice.
- The visible cadence is still 120s whenever the app is frontmost and the workspace has labels, which for a normal working day is most of the time. The saving is real but it is a BACKGROUND saving; a genuinely cheap foreground sweep needs the v2 `includeLabels` embed, which is the upstream ask already filed in the PR-queue note.
- `labelIndex` adds a `CachedConversation` thread-id walk to every index reload that the old `labelIDsByThread` did not do. It is one indexed string column through a batched enumerate, against a conversation-table walk the reload was doing anyway, and it is what buys the badge/listing agreement.

Tests: `LabelSweepCostTests` (cadence gating both cosmetic and behavioural, unchanged-sweep skip, explicit-refresh bypass, capped-walk-records-no-digest), `LabelCacheTests.badgeCountsResolvedThreads` / `unusedLabelCountsZero` / `chunkedListingKeepsItsOrder`, `LabelsTests.badgeCountsArePrecomputed` / `badgeFollowsAnOptimisticToggle` / `labelWriteReloadsTheIndexOnce` / `labelSurfaceSignalFollowsTheUI`.
