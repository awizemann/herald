---
id: t-7d2e71be
title: Upstream PR #34 (`hqbase domain`): address bermanto's changes-requested review
status: done
added: 2026-08-18
priority: high
---

## Description

Scratch worktree /private/tmp/claude-501/.../scratchpad/hqbase-pr34 (branch pr34/domain-move, rebased on upstream main incl. #40). Review asks: (1) --detach leaves the custom domain/DNS attached — need explicit domain deletion; (2) same-release deploy skips BETTER_AUTH_URL update — need a config-only deploy path; (3) non-TTY wrangler auto-overrides existing origin/DNS — inspect changeset, refuse conflicts unless confirmed; (4) manifest/config committed before Cloudflare validates — stage, verify, then commit, with rollback; plus align with the canonical host contract (attach-verify-cutover-redirect, stable machine-facing service origin), companion hqbase-site spec + operator guide, command-level regression tests against real Wrangler behaviour, fail closed around experimental `wrangler triggers deploy`, CI green. Nothing pushed/posted without Alan's approval.

## Plan



## Artifacts

Pushed pr34/domain-move → fork feat/hqbase-domain-move (fix-up 5e99c21 on top of ba45d3b); reply posted https://github.com/HQBase/hqbase/pull/34#issuecomment-5336367694; companion docs PR https://github.com/HQBase/hqbase-site/pull/14 (2 commits, gate green). Awaiting bermanto: API-token question, workspace_hosts write path, install pinning BETTER_AUTH_URL, grace period.

