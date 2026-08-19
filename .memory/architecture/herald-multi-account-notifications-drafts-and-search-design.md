---
title: Herald Multi-Account, Notifications, Drafts and Search Design
type: note
permalink: hqbase-mac/architecture/herald-multi-account-notifications-drafts-and-search-design
tags: [accounts, notifications, drafts, search, attachments]
source_paths: [Herald/App/AppEnvironment.swift, Herald/App/MailViewModel.swift, HeraldKit/Sources/HeraldKit/Sync/SyncEngine.swift, HeraldKit/Sources/HeraldKit/Notifications, HeraldKit/Sources/HeraldKit/Compose/AttachmentLimits.swift]
source_paths_inferred: false
source_sha: 37e925193f7c89c076f83ae4c757b24f7cf5d415
created: 2026-08-18
updated: 2026-08-18
---

Landed 2026-08-18 in five phases (multi-account, attachments polish, notifications, drafts folder, two-tier search). Investigation report: documents/reports/feature-investigation-2026-08-18.md; upstream Issue drafts: documents/upstream/issues-2026-08-18/.

## Observations
- [fact] AppEnvironment is the per-account composition root: `graphs: [Account.ID: AccountGraph]` (sync engine, MailViewModel, OutboxService, NewMailNotifier per account), `mail` computed from `selectedAccountID` (UserDefaults key `selectedAccountID`); install publishes the new graph synchronously, stops the superseded one after, re-checks `isCurrent` after every suspension; account switch resets only `MiddleColumnView.id(accountID)` #accounts
- [decision] Notifications are LOCAL only (poll-driven): `ChangeSet.isBootstrap` is the single first-listing signal (journal bootstrap, cold legacy pass, new mailbox) and silences a pass; notification-worthy = inbound + unread + inbox; one shared poster/router (UserNotifications confined to Herald/Support/UserNotificationCenterAdapter.swift), Dock badge = `totalUnreadCount` across accounts; setting keys notifications.newMail.enabled / notifications.dockBadge.enabled default ON #notifications
- [decision] Drafts are cached in `CachedDraft` and reconciled by FULL-LIST diff of GET /drafts on their own 60s interval + `SyncEvent.draftsChanged` (drafts are not messages, not in /changes; GET /messages?folder=drafts is dead); `MailStore.openDrafts` fence blocks poll deletion / stale-version overwrite while a composer owns the draft; a drafts 401/403 never fails the mail pass (needs mail:send); Drafts is a special sidebar item, not a ConversationFolder #drafts
- [decision] Search is two-tier: local index (subject/from/to/snippet + cached body ≤4 KB) then GET /conversations?search= for the selected mailbox+folder (Return or <3 local hits, ≤5 pages); server results are held as DTOs and NEVER upserted into the cache (a listing is authoritative there); `MailActionService` accepts a representative message id for uncached threads #search
- [fact] Attachment limits mirror the server in `AttachmentLimits.server` (25 MiB/file, 25 MiB/draft, 20 files — the old 10 MiB client cap is gone); uploads are serialized so the per-draft total cannot race; a compose window that binds ⌘V must forward non-attachable pastes or text paste dies; Quick Look/drag-out use `AttachmentScratchpad` (container temp dir, wiped per launch) #attachments

## Relations
- relates_to [[Herald Architecture]]
- relates_to [[Herald Sync Model]]
- relates_to [[HQBase Mail API v1 Contract]]
