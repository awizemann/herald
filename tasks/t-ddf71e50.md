---
id: t-ddf71e50
title: Sent-reply visibility P3: trigger a sync pass immediately after a successful send
status: done
added: 2026-09-28
priority: high
---

## Description

ComposeViewModel.send() success (Herald/Compose/ComposeViewModel.swift ~825-841) never tells sync anything; the reply waits for the next poll (up to 120s/300s with the wake socket connected). Fix: on success, call the composing account's SyncEngine.refreshNow() (existing, coalesced) via a callback wired in AppEnvironment+Compose (like draftCache). Decision (Alan, 2026-09-28): refresh-after-send only, NO optimistic local upsert of receipt.message. Tests + run the real app to confirm a reply appears in the open thread and the Inbox row updates.

## Plan



## Artifacts

Commit 204a6cf (ComposeViewModel `sent` hook → AppEnvironment+Compose → graphs[accountID]?.sync.refreshNow()). Tests: onlyAnAcceptedSendAsksForASyncPass, anAcceptedSendSyncsTheComposingAccountNow — both discriminating. App 653/653, HeraldKit 471/471. Live in-app check NOT done — tracked separately.

