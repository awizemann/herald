---
id: t-19d0d9ef
title: Follow-ups from 2026-08-18 feature audit (compose test handshake, pendingRoute clearing, stale search field, quotedBody dead code)
status: todo
added: 2026-08-18
priority: low
---

## Description

Left by the final fresh-eyes audit: (1) ComposeAttachmentTests:119,208 fixed-yield negative assertions → proper handshake on GatedOutbox; (2) ComposePrefill.quotedBody + its test are dead → delete; (3) DraftsFolderTests:164 optimistic-delete claim not gated; (4) AppEnvironment pendingRoute never cleared if account never installs/signs out; (5) ConversationListView searchText @State not cleared on revealConversation; (6) MailViewModel+Drafts:88 stale comment; (7) product decision: notification body shows snippet, no hide-previews setting. Plus P1/P5 leftovers listed in Herald P0 Plan note.

## Plan



## Artifacts



