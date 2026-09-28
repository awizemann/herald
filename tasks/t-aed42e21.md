---
id: t-aed42e21
title: Redesign v3 follow-up: scope-aware window title + search in Drafts
status: done
added: 2026-09-28
---

## Description

Alan Q5/Q8 2026-09-28: title = account (All domains) / domain / mailbox address, folder subtitle unchanged; search field stays in Drafts and filters drafts. Also trace whether the Settings account card switches accounts and emits account_switched.

## Plan



## Artifacts

7035392: ListColumn.windowTitle (account/domain/mailbox), shared ListSearchField, local drafts filter. Settings account switch already emits account_switched (test added). 667+471 pass. Minor open: search hiding the selected draft doesn't clear selection.

