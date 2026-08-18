---
title: Upstream PR Queue
type: note
permalink: hqbase-mac/roadmap/upstream-pr-queue
tags:
- upstream
- roadmap
created: 2026-08-16
updated: 2026-08-16
---

Owner decision 2026-08-15: submit upstream changes as separate PRs, in order, smallest first; the
client itself comes last after UI polish. Branches live in the fork ~/Developer/hqbase (whose
`main` is an unrelated squashed history — always branch from `upstream/main`). NOTHING pushed yet.

## Observations
- [done] PR1 OPENED 2026-08-16 as https://github.com/HQBase/hqbase/pull/30 (branch `docs/native-client-oauth`): AGENTS.md generator documents application_type=native + RFC 8252 redirect for native PKCE clients; integration test asserts the text. Needs `pnpm install && pnpm check` before opening; docs-site companion (hqbase-site) mirrors the paragraph #pr1
- [done] PR2 OPENED 2026-08-16 as https://github.com/HQBase/hqbase/pull/31 (branch `docs/conversation-action-id`): OpenAPI documents that `POST /conversations/{id}/{action}` `{id}` is a message id (ConversationSummary.id); Postman regenerated via `node scripts/generate-mail-api-artifacts.mjs --write`; body suggests optionally accepting thread ids as a follow-up #pr2
- [todo] PR3 messages pagination + updatedSince (delta sync) — spec-first in hqbase-site per AGENTS.md, then worker + tests; the substantive one; discuss shape with bermanto first (issue #11 thread) #pr3
- [todo] PR4/last: the client — own repo (trademark: "compatible with HQBase, not affiliated") unless the author wants it under the org; upstream gets a docs link or a transfer #client
- [fact] Order to open: PR1 → PR2 → PR3 → client; only after the owner says push #order

## Relations
- relates_to [[Herald Project Overview]]
- relates_to [[HQBase Mail API v1 Contract]]

## Update (2026-08-16 — PRs opened)
- [fact] `awizemann/hqbase` is an IMPORT (not a fork) so GitHub refuses cross-repo PRs from it; created a true fork `awizemann/hqbase-fork` (local remote `fork`) — PR branches live there; branch from `upstream/main`, never from the import's main #fork
- [gotcha] Upstream requires CLA acceptance via CLA Assistant on every PR (Alan clicks); upstream `pnpm check` has one pre-existing failure under Node 26.5 (`use-draft-autosave.test.tsx` localStorage) — reproduce on pristine main before blaming a branch; run the gate in a clean worktree, the import's untracked `.memophant/*.json` trips Biome otherwise #upstream-gate
- [fact] Upstream 1.1.1/1.1.2 changed no API contract (vendored spec identical after normalization); AGENTS.md moved to /skills/hqbase-mail/SKILL.md; contributor CLA added #upstream-1.1.2

## Update (2026-08-16 — author responses)
- [fact] #30 revised with bermanto's exact wording (2e13bc6) + companion spec PR HQBase/hqbase-site#9 (fork awizemann/hqbase-site, branch docs/native-client-oauth); #31 revised (c881da2) + Postman regenerated; both awaiting his Linux/Windows checks #pr-status
- [fact] #32: Herald wording accepted ("compatible with HQBase"); NOT official yet — door open, "recommended community client"; he tried it on his instance and liked it; asked Alan to join their Discord #adoption
- [todo] PR3 design posted on #11 (comment 5309528757) — awaiting shape approval; PR3.5 candidate: OAuth session binding makes native clients expire with the browser session (see API contract note) #next
- [gotcha] The fork checkout ~/Developer/hqbase is shared with ANOTHER active session (branch feat/hqbase-domain-move) — do upstream PR work ONLY in the scratch worktrees; a `git add -A` there once swept that session's untracked file into a stray commit (restored) #shared-checkout

## Update (2026-08-16 — end of session)
- [fact] Herald repo issues from bermanto: #2 #3 #4 fixed+closed in v0.1.2; #1 fixed UX-side, awaiting his scope evidence; hqbase-site#9 open (companion to #30); #30/#31 revised per review, awaiting his checks; PR3 shape awaiting reply on #11 #status

## Update (2026-08-17 — PR-A opened)
- [fact] #31 MERGED upstream (2026-08-16); #30 + site#9 still open awaiting checks #status
- [fact] PR-A opened per bermanto's approved contract: HQBase/hqbase#35 (feat/messages-pagination on awizemann/hqbase-fork) + spec HQBase/hqbase-site#10; cursor version tag "m1", codes INVALID_LIMIT/INVALID_CURSOR, migration 0012 adds three activity expression indexes (open question: trim to two; ANALYZE) #pr-a
- [todo] PR-B (/changes journal endpoint) after #35 merges — contract in "Upstream Delta Sync Contract (approved)"; then Herald swaps to checkpoint+changes #next
- [fact] 2026-08-17: #30 + site#9 MERGED (all three doc PRs now in). #35 review: keep 3 indexes + add `PRAGMA optimize` (planner has no stats for new indexes; broad-access `mailbox_id IN (...)` no-folder shape stayed on a temp B-tree) — applied in bfadc1e with a discriminating plan test; awaiting re-review. quality-windows failures = unrelated users.test.ts timeouts #pr-a
- [gotcha] D1/SQLite: after CREATE INDEX in a migration, run `PRAGMA optimize` or the planner may not choose the new index (no sqlite_stat1) — Cloudflare's guidance; verify with EXPLAIN QUERY PLAN in a migration test #d1

## Update (2026-08-17 evening — PR-A merged)
- [done] HQBase/hqbase#35 (messages pagination) APPROVED + MERGED 2026-08-17 23:01; hqbase-site#10 merged. Every PR opened so far (#30 #31 #35, site#9 #10) is in upstream #pr-a
- [todo] PR-B (/changes journal endpoint) is next per the author's ordering; contract in "Upstream Delta Sync Contract (approved)"; needs Alan's go #pr-b
- [todo] Herald: adopt limit/cursor/Link on GET /messages and drop the 100-cap guard once an HQBase release includes #35 (Alan's instance is on 1.1.x today) #herald

## Update (2026-08-18 — changes feed shipped UPSTREAM by the author)
- [fact] bermanto built the changes endpoint himself: HQBase/hqbase#37 "Add a durable Mail API changes feed" merged 2026-08-18 01:18 (+ site#11 spec), closing #11. Migration 0013 = message_changes journal + insert/update/delete triggers; GET /api/v1/changes {cursor?, limit 1-100} → MessageChangePage {changes:[upsert{message}|delete{messageId,mailboxId}], nextCursor, hasMore}; no cursor = checkpoint; 410 defined. PR-B is MOOT — Herald adoption (t-8a1c0042) is the work now #pr-b
- [fact] Herald vendored the new spec (2026-08-18); generator emits `listMessageChanges` + `MessageChange` enum + `MessageChangePage`; existing 120 kit tests unaffected #herald

## Update (2026-08-18 — close)
- [fact] Open upstream threads: #41 (refresh-token reuse interval), #42 (restore action + document folder restrictions), #32 (adoption: recommended community client). Herald #7 blocked on #42. All PR branches deleted from awizemann/hqbase-fork (everything merged) #status
