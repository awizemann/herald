---
title: Upstream PR Queue
type: note
permalink: hqbase-mac/roadmap/upstream-pr-queue
tags:
- upstream
- roadmap
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
