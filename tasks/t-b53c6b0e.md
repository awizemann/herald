---
id: t-b53c6b0e
title: Honor mailbox/domain active status in the domain list
status: done
added: 2026-09-27
priority: high
---

## Description

Herald's sidebar lists domains that were disabled in HQBase (backfill.company, scarfbox.co, walkabout.run; keyrole.com is also disabled but has no mailbox, so it never showed up).

Root cause (2026-09-27): Herald works out its domain list from GET /api/v1/mailboxes (MailDomain.domains(from:)). The server has two on/off switches:
- `Mailbox.isActive` (the mailbox's Disable toggle): sent in v1, but Herald decodes and caches it and then ignores it.
- `mail_domains.is_enabled` (the domain's Active toggle): not in v1 at all. Only the admin /api/domains endpoint has it, and that is outside the v1 contract. This is the switch Alan actually flipped; every mailbox in the cache is still isActive=1.

Scope:
1. Herald: stop showing disabled mailboxes, and drop any domain left with no active mailboxes.
2. Upstream HQBase: draft an issue and PR adding an optional `domainEnabled` field to v1 `MailboxAddress`. Draft only: nothing is pushed or filed without Alan's OK. Then have Herald honor the field when the server sends it (servers without it keep today's behaviour).
3. An independent audit of both.

## Plan



## Artifacts

- Herald (branch `redesign`, not pushed):
  - 1bc5c1c: hide server-disabled mailboxes and domains
  - 71d77e2: audit fixes (the list updates live, replies keep their mailbox, safe spec re-vendoring, stable monograms, no banner from a disabled mailbox)
  - Tests: 569 + 467 passing. A pre-existing flaky label-sync test failed once, then passed on 2 reruns.
- HQBase upstream draft (NOT pushed or filed):
  - Worktree: scratchpad/hqbase-domain-enabled, branch feat/v1-mailbox-address-domain-enabled, commits 4f7f431 + 3f75bf3 on upstream/main a1161f1
  - Patch: scratchpad/hqbase-domain-enabled.patch
  - Issue and PR text: documents/plans/hqbase-upstream-domain-enabled-2026-09-27.md
- Before filing: the hqbase-site spec change (AGENTS.md wants the spec changed first); Alan approves the push and PR.
- Decision record: decisions/herald-redesign-r2-domain-model-and-herald-only-preferences.md (2026-09-27 update)

