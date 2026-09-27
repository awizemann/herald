---
id: t-ec625ced
title: Session recovery P6: harden latch, late consent, handler wiring, composer saves
status: done
added: 2026-09-26
priority: high
---

## Description

From documents/reports/session-recovery-audit-2026-09-26.md: D2 latch only on explicit error="invalid_token"; D3 kept late consent installs graph (select:false) + W8 re-auth never steals selection; D6 set handler in activate + D9 test through activate; D4 serialize composer save/create across rebind; W9 sign-out cancels (not awaits) automatic attempt; W11 re-check grant before announcing; D8 fix test claim; nits (banner cancelledByUser per account, signed-out Save Draft feedback, drop test-only isCancellableReauthentication).

## Plan



## Artifacts



