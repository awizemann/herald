---
title: Herald Multi-Account, Notifications, Drafts and Search Design
type: note
permalink: hqbase-mac/architecture/herald-multi-account-notifications-drafts-and-search-design
tags: [accounts, notifications, drafts, search, attachments]
source_paths: [Herald/App/AppEnvironment.swift, Herald/App/MailViewModel.swift, HeraldKit/Sources/HeraldKit/Sync/SyncEngine.swift, HeraldKit/Sources/HeraldKit/Notifications, HeraldKit/Sources/HeraldKit/Compose/AttachmentLimits.swift]
source_paths_inferred: false
source_sha: 4bd3bd4711d71c167135f7abec683bff2693f91a
created: 2026-08-18
updated: 2026-09-26
reviewed: 2026-09-19
reviewed_by: audit:claude-code (background)
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
- relates_to [[Herald Wake Socket Architecture]]
- relates_to [[Herald Label Caching and UI Architecture]]
- relates_to [[Sign-In Recoverability and the Presentation Watchdog]]


## Update (2026-09-04)
- [fact] The polling design here is now the FALLBACK tier: upstream 1.3.4's `GET /events` wake WebSocket (see [[Herald Wake Socket Architecture]]) stretches the poll to 120s/300s while connected; drafts refresh is also wake-driven (`drafts` topic). Labels landed as a new sidebar surface with its own 120s sweep (see [[Herald Label Caching and UI Architecture]]) #wake-socket


## Update (2026-09-26 — composer lifecycle per account, session-recovery P4, commit f3a2255)
- [invariant] Compose sessions are bound to the account they were opened from (`ComposeSession.accountID`), and account lifecycle events touch ONLY that account's composers: re-install (re-auth) → `rebindComposeSessions(accountID:to:)` moves live composers onto the new graph's OutboxService (session, text and send key kept); sign-out / `stopGraph` → `closeComposeSessions(accountID:)` removes sessions and marks composers `accountSignedOut()` (send-blocked, no network, text kept in the window). The compose error bar's Sign In re-auths the composer's own account, not the selected one. Details: [[Sign-In Recoverability and the Presentation Watchdog]] #accounts #compose-reauth



## Update (2026-09-26 — P8 account-store safety + offline launch: inputs for the origin+sub multi-account project)
- [decision] Interim W1 guard: Add Account refuses an origin already signed in (live or in the Keychain index) before OAuth; re-auth unaffected. REMOVE/relax it when identity becomes origin+sub — then a second user on the same origin is a new account, and the guard must instead compare the returned `sub` after consent. Details: [[Herald Architecture]] #add-account-guard
- [fact] Ready for the identity change: `store.add` already merges (label/userEmail survive re-auth), the index tolerates added keys (e.g. `sub`) in BOTH directions (older builds ignore unknown keys; this build preserves them on rewrite), and undecodable entries are never dropped. Do NOT change existing field names/types or the bare-array top level while an older build may share the Keychain — the older build overwrites an index it cannot decode. Also: `Account.merging(over:)` keeps the stored label/userEmail and assumes the SAME user — merge only when sub matches; and `add` collapses duplicate-`id` entries (`remove` drops all of them), so the new identity must give each user a distinct `id` #account-index
- [gotcha] Open risks carried forward from the P8 audit: `OAuthDiscovery.endpointsAreTrusted` compares scheme+host but NOT port (pre-existing, live discovery too) and the persisted `resource` is not re-checked against `Account.resource(for:)`; a `discovery.<origin>` item created by one build may raise a login-keychain access prompt in a differently-signed build (same class of issue as the index/tokens items; denial = cache miss) #offline-activation
- [gotcha] Keys that are per-ORIGIN today and must stay per-origin (shared by all accounts on a server): `client.<origin>` and `discovery.<origin>`. `AuthCoordinator.signOut` evicts the discovery cache (memory + persisted) by origin UNCONDITIONALLY — with several accounts per origin, evict only when no other account uses the origin (harmless otherwise, but costs the survivor its offline activation until the next successful discovery). `tokens.<accountID>` becomes per-(origin+sub) with the new id #keychain-layout
- [fact] Activation now effectively never fails (no network in `tokenProvider(for:)`), so `activate`'s `.failed`/`launch_failed(kind: other)` branch is near-dead. Placeholders/retry UI for accounts that cannot activate (W4 "later") remain multi-account scope; restore tests observe activation via `InMemoryAccountStore.configurationReads` rather than `launch_failed` counts #offline-activation
