---
title: HQBase Local Test Instance (v1.3.4)
type: note
permalink: hqbase-mac/operations/hqbase-local-test-instance-v1-3-4
created: 2026-09-04
updated: 2026-09-04
---

## Observations
- [fact] Local HQBase test instance runs entirely offline via `pnpm dev` (= `pnpm build && wrangler dev --port 8787`) in a git worktree of ~/Developer/hqbase checked out at tag v1.3.4; all bindings (D1, R2, Durable Object, Queue) run as wrangler local simulators, no Cloudflare account/credentials needed #setup
- [fact] Setup sequence in a fresh worktree: `pnpm install` then write `.dev.vars` with BETTER_AUTH_SECRET + HQBASE_LOCAL_SEED_PASSWORD, then `pnpm db:migrate:local`, then `pnpm db:seed:local` (seeds owner@hqbase.test), then `pnpm dev`; base URL is http://localhost:8787 #procedure
- [fact] Verified 2026-09-04: worktree at scratchpad/hqbase-134 (tag v1.3.4, commit 895757e), GET http://localhost:8787/api/v1/openapi.json returns 27 paths including all 1.3.4 additions: /api/v1/events, /api/v1/forward, /api/v1/drafts/changes, /api/v1/labels (+ per-resource label sub-routes), /api/v1/signatures #verified
- [gotcha] Keep this test worktree SEPARATE from ~/Developer/hqbase itself, that checkout is shared with another live session (currently on feat/hqbase-domain-move) and must not be disturbed or committed in; use `git worktree add <path> v1.3.4` instead of checking out the tag in place #isolation
- [fact] Production hqbase.alanwizemann.com (a separate deployed worker) was NOT touched by this upgrade; this test instance is local-only (wrangler dev), not a deployed Cloudflare Worker #scope

## Relations
- relates_to [[HQBase Mail API v1 Contract]]
