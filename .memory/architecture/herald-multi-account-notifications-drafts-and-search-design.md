---
title: Herald Multi-Account, Notifications, Drafts and Search Design
type: note
permalink: hqbase-mac/architecture/herald-multi-account-notifications-drafts-and-search-design
tags: [accounts, notifications, drafts, search, attachments]
source_paths: [Herald/App/AppEnvironment.swift, Herald/App/MailViewModel.swift, HeraldKit/Sources/HeraldKit/Sync/SyncEngine.swift, HeraldKit/Sources/HeraldKit/Notifications, HeraldKit/Sources/HeraldKit/Compose/AttachmentLimits.swift]
source_paths_inferred: false
source_sha: 2d441e9a9ad57500bef916f829b4ad0b9934e258
created: 2026-08-18
updated: 2026-09-28
reviewed: 2026-09-29
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
- relates_to [[herald-signature-handling]]
- relates_to [[Herald Design System and Accessibility]]


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



## Update (2026-09-27 — redesign R3a)
- [fact] CORRECTION: Drafts is now the `.drafts` case of `MailViewModel.Folder` (still not a `ConversationFolder`) and is filtered by scope — only All domains lists drafts with no mailbox. The server search tier asks for the picked mailbox only in a `.mailbox` scope; a domain or All domains searches every mailbox and filters the answer client-side to the scope's mailbox set. Details: [[Herald Architecture]] (R3a update) #drafts #search



## Update (2026-09-27 — redesign R3b: per-domain notifications, badge, click routing; commit 0d7d327)
- [decision] Banners: `NewMailNotifier.handle(_:accountID:accountLabel:silencedMailboxIDs:)` — the app passes, PER PASS, the mailboxes of domains that are `hidden` or have `notify == false` (`MailViewModel.notificationSilencedMailboxIDs()` — cached per mailbox list + preferences revision since F1, so it only moves after `domainPreferencesDidChange()`); HeraldKit stays ignorant of `DomainPreferences`. A mailbox-less message is never silenced. Silenced arrivals are `remember`ed (not announced later) and don't count toward a burst #notifications
- [decision] The global "Notify me about new mail" is the MASTER switch: `notify == nil` follows it, `false` silences the domain, and an explicit `true` does NOT override a global OFF (a domain toggled off→on stores `true`, and would otherwise keep posting after the user silenced Herald). R8's per-domain toggle should read as disabled/off while the global switch is off #notifications
- [decision] Dock badge = Σ accounts' `MailViewModel.badgeInboxUnread` (Inbox unread over `badgeMailboxIDs()`: excludes `hidden` and `countInBadge == false`, NOT `includeInAll`), still gated by the global dock switch. `AppEnvironment.unreadCount(forAccount:)` (account list/card) = `allDomainsInboxUnread`. Sidebar counts are always Inbox (N6): `inboxUnreadByMailbox`, `inboxUnreadByDomain` (DISTINCT threads over the domain's mailboxes — `UnreadTally`; `sumByDomain` is gone since F1 because summing double-counted a thread in two mailboxes), `allDomainsInboxUnread` (distinct threads over the same set the All domains listing reads, unassigned rows included); all derived from one `unreadConversationKeys` read. After writing a `DomainPreferences` toggle call `MailViewModel.domainPreferencesDidChange()` (reloads list + counts + badge) #badge
- [decision] Click routing: `revealConversation` lands on All domains › Inbox unless All domains excludes something AND the thread's inbox row is not in the All domains set — then `.domain(<thread's domain>)` (resolved via `store.messages(threadID:)` → mailbox → domain). A hidden domain is never a landing place #notifications
- [decision] Sign-out notifications (F1, 2026-09-28): after the revoke, if no sign-in raced back in, `AppEnvironment.forgetNotifications(forAccount:)` drops a held `pendingRoute` for the account and calls `NewMailNotificationPosting.removeDelivered(forAccount:)` (protocol requirement with a no-op default in a `nonisolated extension`; the adapter matches delivered banners by `NewMailNotification.identifierPrefix(accountID:)` = `herald.newmail.<id>.` AND the payload's accountID — the prefix alone is ambiguous for `https://mail.x` vs `https://mail.x.y`). Runs whether or not the revoke succeeded #sign-out #notifications
- [decision] Sign-out (`AppEnvironment.signOut`, same `graphs[accountID] == nil` guard as the cache purge) calls `PreferenceHygiene.purgeAccount` ONLY when `auth.signOut` SUCCEEDED (F1) — a failed Keychain half brings the account back at the next launch, and it must come back with its settings: `DomainPreferences.purgeAll` + `sidebar.{scope,folder,label,mailbox}.<id>` + `account.<id>.tint`, exact keys (prefix-safe for `https://mail.x` vs `https://mail.x.y`). Tests: `HeraldTests/DomainEffectsTests.swift` #sign-out



## Update (2026-09-28 — compose redesign v3)
- [pointer] Compose From rules (default From by scope, reply From = address the original was sent to, From↔mailboxID coupling, signature reset on From change) live in [[herald-signature-handling]] (V5, commit bd1e15a; code `Herald/Compose/ComposeFrom.swift`). Compose window layout/token-field gotchas live in [[Herald Design System and Accessibility]] (V6, 2df748a).



## Update 2026-09-28 — window title per scope, Drafts search (commit 7035392)
- Window title = `ListColumn.windowTitle(scope:accountLabel:scopeName:)`: account label at All domains, domain name inside a domain, mailbox address inside a mailbox. Subtitle stays the folder; Window menu follows automatically.
- Toolbar search is one `ListSearchField` modifier (ConversationListView.swift) applied to BOTH ConversationListView and DraftListView, so the field never disappears/shifts in Drafts. Drafts filter LOCALLY via `ListColumn.filterDrafts` (subject, recipients, snippet; case-insensitive; trimmed) → `MailViewModel.presentedDrafts`. The API's `GET /drafts?search=` exists but is unused: the cache already holds every draft of the scope. `searchQuery` survives folder switches, same as other folders. Drafts' empty search = "No Results" without the Return hint (no server search in Drafts).
- Settings account card switches via `selectAccountFromSettings`, which assigns `selectedAccountID` directly and so already emits `account_switched`; pinned by a test in UsageInstrumentationTests.
