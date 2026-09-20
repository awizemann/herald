---
title: Herald Label Caching and UI Architecture
type: note
permalink: hqbase-mac/decisions/herald-label-caching-and-ui-architecture
tags: [labels, sync, swiftdata, ui]
source_paths: [HeraldKit/Sources/HeraldKit/Sync/MailStore+Labels.swift, HeraldKit/Sources/HeraldKit/Sync/SyncEngine.swift, HeraldKit/Sources/HeraldKit/Sync/CachedModels.swift, HeraldKit/Sources/HeraldKit/Sync/MailActionService.swift, HeraldKit/Sources/HeraldKit/Model/MailLabel.swift, Herald/App/MailViewModel+Labels.swift, Herald/Design/LabelChip.swift, Herald/Views/SidebarView.swift]
source_paths_inferred: false
source_sha: 7e5eb159db68edaac988bfd21ae27c5ae670639d
created: 2026-09-04
updated: 2026-09-19
reviewed: 2026-09-09
reviewed_by: audit:claude-code (background)
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


## Membership from ROWS (U2, task t-bdd6b056, 2026-09-19 — commit 77f6614)

**The premise this whole note was written on is now the LEGACY half.** The opening
line ("v1 message/conversation/change payloads carry no `labels` field") and the
first `#sync` observation are true only of servers below 1.4.2 — still supported
(the floor is 1.3.4, and production auto-update offered 1.4.0), so both halves are
live code, but the 1.4.2 path is the primary one. The "residual risk" recorded in
the A3 section — *"a genuinely cheap foreground sweep needs the v2 `includeLabels`
embed, which is the upstream ask already filed"* — is RESOLVED: upstream shipped it
on v1 as our #115.

- [decision] Membership is written from the ROWS Herald already fetches.
  `MailStore.applyEmbeddedLabels(from:accountID:)` takes summaries and replaces the
  label set of each one that STATES a set. It is called from
  `applyMessageUpserts` — the single funnel for journal upserts, folder listings
  and triage-action answers — and from `MailViewModel.storeEmbeddedLabels(of:)` for
  the single-message and thread routes, which the view fetches and never stores.
  `setMessageLabels` (the `LabelAssignmentResult` path) shares its batched core
  `writeMessageAssignments`, so a 100-row journal page is one fetch and one save
  instead of 100 of each #sync
- [constraint] `nil` vs `[]` on `MessageSummary.labels` is enforced here: `nil` is
  skipped (the key was absent — old server, or nobody asked), `[]` clears. The
  embedded write is per-MESSAGE and touches no other row, so unlike
  `replaceAssignments` it can never erase a label's wider membership #sync
- [decision] `SyncEngine.labelMembership`'s per-label sweep is now a
  RECONCILIATION on `defaultReconciliationLabelPollInterval` (1800s) once the
  server is detected as embedding, plus two prompt triggers: the `labels` wake
  frame (`refreshLabelsNow()`, unchanged) and any change to the label LIST, which
  drops `lastSweepDigests` so every label is rewritten authoritatively. It is kept
  because rows can only ever ADD to the picture — a label DELETED workspace-wide
  touches no message and no row will ever mention it again, and the sweep is also
  what stores assignments for messages in folders this cache has never listed (the
  `#sweep-unknown-ids` / `#completeness` facts still stand) #sync
- [decision] Detection is by RESPONSE SHAPE, per account, per session
  (`SyncEngine.labelEmbeddingAccounts`): the first summary with non-`nil` labels
  proves it, `[]` included. Never a version number. An undetected account keeps the
  legacy 120s/750s cadence and its visible/idle surface signal — which therefore
  now only decides anything on a pre-1.4.2 server, though `MailViewModel` keeps
  reporting it either way (choosing the regime is the engine's job) #sync
- [gotcha] A label-only edit is a journal upsert with every message FIELD
  unchanged, so the `ChangeSet` is empty and `.changed` never fires while the chips
  are wrong. `MessageUpsertResult.labelsChanged` carries it instead and the engine
  drains it into ONE `.labelsChanged` per pass #ui
- [fact] `upsertConversations` deliberately does NOT write the labels embedded on
  `latest`: every message a conversation row can name also arrives as a message
  row in the same pass, and two writers for "this message's labels" inside one pass
  buys no coverage #sync
- [gotcha] The A3 race ("a sweep that started before a local toggle deletes the
  just-confirmed row") is NARROWED further but still not fixed: at 1800s the window
  is far rarer, and rows now correct the cache continuously between sweeps #race

Tests: `LabelSyncTests` gained `journalLabelsUpdateMembershipWithoutASweep`,
`absentLabelsKeyChangesNothing`, `embeddingIsDetectedFromTheFirstStatedRow`,
`labelListChangeForcesReconciliation`,
`reconciliationStillReplacesOnAnEmbeddingServer`,
`conversationUnionMatchesTheServerAnswer` and (cache suite)
`embeddedLabelsAreScopedToTheirMessages`; `HeraldTests/LabelsTests` gained
`viewFetchedLabelsReachTheChips`. HeraldKit 318 → 325, app-hosted 255 → 256.


## The label fence, and `.labelsChanged` on every pass exit (F1, task t-c77df387, 2026-09-19 — commit 1d3a614)

The U2 audit (`documents/reports/audit-2026-09-19-hqbase-142-adoption.md`, C1/C2)
found that making ROWS the membership source created a new race and left an old
announcement gap. Both are fixed here.

- [decision] **The pending-mutation fence now covers labels, and its pinned unit
  is the PAIR `(accountID, messageID, labelID)`** (`MailStore.pinnedLabels`,
  `LabelPinKey`). Not the message: the triage fence pins three FIELDS of a row
  and an action writes all of them at once, but a message carries several labels
  at a time, so pinning the row would fence every other label on it against the
  very pages meant to keep them current. The value is a SET of action tokens, so
  the same pair can be in flight twice (a message toggle and its thread's) and
  the first to settle does not unpin rows the second still owns #fence
- [decision] **Who may cross it.** An EMBEDDED write — `writeMessageAssignments`
  called from `applyEmbeddedLabels`, i.e. a journal page or a folder listing —
  and the reconciliation's `replaceAssignments` must leave a pinned pair exactly
  as the cache has it, in BOTH directions (no insert, no delete; the re-thread
  fixup is skipped with it). The action's OWN settle (`setMessageLabels`,
  `settleThreadLabel`) passes `respectingPins: false`, because it is the newer
  statement and it is what takes the fence down #fence
- [gotcha] **The fan-out is the whole thread, not the undo.** `LabelActionUndo`
  carries only the rows that actually MOVED (a message that already had the
  label contributes nothing, or a revert would remove a label the action never
  granted), so `undo.pinned` is a deliberate superset: a conversation toggle
  pins every cached message of the thread. Taking the pins from `undo.messages`
  would leave the already-labelled siblings unfenced #fence
- [rule] **Release on every exit.** `MailActionService` releases at all six:
  settle, a settle that itself threw, and an API rejection after the revert, in
  both the message and conversation methods. Pins are also cascaded on the
  delete paths (`deleteMessage`, `deleteMissingMessages`, `purgeMailbox`) and on
  `deleteAll`, beside `pendingMutations`. A LEAKED PIN IS WORSE THAN THE RACE:
  it fences that pair against the server for the rest of the session, so the
  chip can never be corrected again #fence
- [decision] **The A3 race is NARROWED, not fixed.** "A sweep that started
  before a local toggle deletes the just-confirmed row" can no longer happen
  while the toggle is IN FLIGHT — `replaceAssignments` honours the pins. The
  residue is a sweep whose listing predates a toggle that has already SETTLED:
  the fence is down by then, by design (holding it longer would freeze the pair
  against the server indefinitely, and the settle wrote the server's own
  answer). At the 1800s reconciliation cadence, with rows correcting the cache
  continuously in between and the digest suppressing an unchanged sweep, that
  window is small and self-healing #race
- [fact] `MailStore.hasLabelPin(messageID:labelID:accountID:)` is the test seam,
  mirroring `hasPendingMutation`. Tests (all mutation-checked — removing the
  fence fails all four): `staleEmbeddedLabelsCannotStripAnInFlightToggle`,
  `theFenceIsScopedToItsPair`, `theThreadToggleFencesTheWholeFanOut`,
  `aRejectedChangeReleasesTheFence`, `theSweepRespectsTheFence` #testing

Also in this pass: `MailViewModel+Labels.updateLabelSurfaceVisibility` now sets
`isLabelSurfaceVisible` only AFTER the engine hop, and returns early when `sync`
is nil — setting it first made the flag a record of INTENT, and the launch path
runs before the engine is installed, so the guard then swallowed every later
call until the value flipped and flipped back (audit P12).

Structural: `SyncEngine.swift` 1352 → 996 lines; the labels region is now
`SyncEngine+Labels.swift` and the drafts region `SyncEngine+Drafts.swift`.
Stored properties stay on the actor (an extension cannot declare storage), and
the members the extensions reach are internal rather than `private` — which is
file-scoped, so `fileprivate` would not have helped either.
