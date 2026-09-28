---
id: t-c01fa50d
title: Sent-reply visibility P2: re-list every conversation scope holding an upserted thread
status: done
added: 2026-09-28
priority: high
---

## Description

SyncEngine.flush -> conversationScopes (HeraldKit/Sources/HeraldKit/Sync/SyncEngine.swift ~837-862) only re-lists the upserted message's OWN folder scope (+starred). A reply lands in `sent`, so the cached Inbox/Archive CachedConversation row keeps a stale messageCount/latest; isMultiMessage (MailViewModel.swift ~781) then treats the thread as single-message. Fix: also touch every cached conversation scope that already contains the message's threadID (query via MailStore, @ModelActor — charter C3). Discriminating Swift Testing tests with the URLProtocol fake server.

## Plan



## Artifacts

Commit 4309552 (MailStore.threadListings + SyncEngine.flush + test replyRefreshesTheThreadsOtherListings). HeraldKit suite 471/471 pass; test proven discriminating. Memory: decisions/Herald Sync Model gotcha line updated.

