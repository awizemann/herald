---
id: t-9cc83ef8
title: Session recovery P1: dead-session latch in AccountTokenProvider
status: done
added: 2026-09-26
priority: high
---

## Description

Plan: documents/plans/session-recovery-2026-09-26.md §P1. Per-account token provider latches a grant that was rejected after refresh, fails fast (no refresh storm), clears when the Keychain holds a different grant, and announces the rejection once so the app can route it.

## Plan



## Artifacts



