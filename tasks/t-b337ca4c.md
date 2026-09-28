---
id: t-b337ca4c
title: Redesign v3 follow-up: app fonts everywhere + analytics events
status: done
added: 2026-09-28
---

## Description

Alan 2026-09-28 (open questions Q1, Q2): replace system text styles with MailTheme.Typography (Geist/Source Serif/Geist Mono) app-wide; remove UsageEvent.mailboxColorChanged; ensure account switching and domain switching emit analytics events.

## Plan



## Artifacts

9574175 app fonts + AppFontGuardTests; a78106a removed mailboxColorChanged, added scope_changed. 663+471 tests, UI tests pass.

