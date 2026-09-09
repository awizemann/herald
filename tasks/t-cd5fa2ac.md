---
id: t-cd5fa2ac
title: P0: upgrade local HQBase test instance to 1.3.4 for live verification
status: done
added: 2026-09-04
priority: high
---

## Description

Local test instance is behind (production hqbase.alanwizemann.com is on latest and stays untouched). Find how the local/test instance is deployed (search Memophant memory/vendors + ~/Developer/hqbase), upgrade to v1.3.4, verify /api/v1/openapi.json serves the new routes (events, forward, drafts/changes, labels, signatures).

RESULT (2026-09-04): DONE. Upgraded and verified. Test instance = `pnpm dev` (wrangler dev, local-only D1/R2/DO/Queue simulators, no Cloudflare account/credentials required) run from a separate git worktree of ~/Developer/hqbase checked out at tag v1.3.4 (commit 895757e), at /private/tmp/claude-501/-Users-awizemann-Developer-hqbase-mac/e7c2d06a-a5d9-41bc-a192-af20fbb36284/scratchpad/hqbase-134 — kept isolated from the shared main ~/Developer/hqbase checkout (which is on another session's feat/hqbase-domain-move branch and was not touched). Base URL: http://localhost:8787. Server currently running in background (nohup, log at .../scratchpad/hqbase-134-dev.log).

Verified GET http://localhost:8787/api/v1/openapi.json returns 27 paths including all 1.3.4 additions: /api/v1/events, /api/v1/forward, /api/v1/drafts/changes, /api/v1/labels (+ per-message/conversation/draft label sub-routes), /api/v1/signatures.

Memory note written: hqbase-mac/operations/hqbase-local-test-instance-v1-3-4 (setup procedure, gotchas, verification). Production was not touched. No blockers.

## Plan



## Artifacts



