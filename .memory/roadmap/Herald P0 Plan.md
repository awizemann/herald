---
title: Herald P0 Plan
type: note
permalink: hqbase-mac/roadmap/herald-p0-plan
tags:
- roadmap
- p0
---

P0 = a usable read/triage/reply client against a v1.1.0 HQBase: add account (origin + OAuth PKCE),
three-pane mail UI, conversation list, reading pane (sanitized HTML), triage actions with keyboard,
reply/new message (plain text), local cache for instant launch, polling sync.

## Observations
- [fact] Phases: P0.1 scaffold+kit (project.yml, HeraldKit, generated API client, DTOs, KeychainStore); P0.2 auth (discovery, dynamic registration, PKCE via ASWebAuthenticationSession, refresh, AccountStore); P0.3 sync+store (SwiftData cache, MailStore, SyncEngine, fake-server tests); P0.4 UI (MailViewModel, split view, list, reading pane, actions, Commands); P0.5 compose (reply/new, OutboxService); P0.6 audit + polish + build-detached #phases
- [fact] Deferred past P0: attachments upload UI, drafts sync UI, search, multiple accounts UI (model supports it), notifications, HTML compose, iOS target #deferred

## Relations
- relates_to [[Herald Architecture]]
- relates_to [[Herald Sync Model]]

## Update (2026-08-15 — P0 complete)
- [done] P0.1–P0.6 shipped on main (9 commits): 112 kit + 32 app discriminating tests green under Swift 6.4 / Xcode 27b; three read-only specialist audits (concurrency, security, testing) + two UI audits (SwiftUI, a11y/perf) → 41 verified fixes applied #status
- [todo] NOT yet dogfooded against a real HQBase ≥1.1.0 server — first real-server run is the next step (add account → OAuth consent → sync → reply) #next
- [todo] Follow-ups ticketed: optimistic-vs-sync fence; Keychain I/O off main; PrivacyInfo.xcprivacy; per-draft 25 MiB total cap; ⌘F search focus; WebKit-level navigation-policy test; multi-account UI; attachments in compose UI polish; drafts folder UI #followups

## Update (2026-08-15 evening — first real-server run SUCCEEDED)
- [done] Dogfooded against https://hqbase.alanwizemann.workers.dev (HQBase 1.1.0): OAuth PKCE consent → account added → sync of 3 mailboxes → inbound test mail appeared via poll with unread state, thread count, reply threading. Four real-server fixes needed and all recorded in the API-contract note: application_type=native, RFC 8252 reverse-domain redirect, keychain-access-groups entitlement, @Sendable framework callback #dogfood
- [todo] Sidebar status shows "Syncing…" for long stretches — verify pass duration (3 mailboxes × 4 folders × 2 list calls per pass at 15s cadence) and consider showing idle between passes / a subtler indicator #polish
- [todo] Next dogfood steps: open the message (HTML render + remote-media trust), reply from Herald, archive/trash + keyboard, star, second account #dogfood
- [done] 2026-08-15 late: reply from Herald round-trips (web + app); post-send close no longer prompts; server-side quoting confirmed and client quoting removed. Real-server fixes so far: 6 (native app_type, RFC 8252 redirect, keychain group, @Sendable callback, sidebar mailbox reload, sent-composer close, no client quote) #dogfood
- [done] HTML rendering + remote-media trust verified on a real Substack forward (blocked → Load Remote Images → images); "Syncing…" is NOT stuck — it shows during each 15s pass; polish = quieter indicator, not a bug #dogfood

## Update (2026-08-16 — v0.1.0 SHIPPED)
- [done] Herald v0.1.0 published: https://github.com/awizemann/herald/releases/tag/v0.1.0 — verified from a cold download: Gatekeeper accepted (Notarized Developer ID), stapled, sandboxed, Sparkle entitlements + public key present, appcast live at https://awizemann.github.io/herald/appcast.xml #shipped
- [todo] Only untested pipeline link: an installed 0.1.0 self-updating to 0.1.1 via Sparkle (t-8a1c0028) #next
- [todo] Then: open the adoption/trademark issue on HQBase/hqbase linking the release; open PR1/PR2 from the fork branches (need `pnpm install && pnpm check` first) #upstream

## Update (2026-08-16 — v0.1.1 shipped)
- [done] v0.1.1 published (build 2): https://github.com/awizemann/herald/releases/tag/v0.1.1 — notarized, appcast updated via release.sh (NOTARY_PROFILE=shabubox-notary); contents: per-mailbox chip colors + Settings, humanized dates, row layout (sender line, right-justified date, aligned tool column, count left of chevron), SnippetCleaner, drill-on-select, newest-first thread view #shipped
- [todo] Owner verifies Sparkle self-update from installed 0.1.0 → 0.1.1 (t-8a1c0028) #next

## Update (2026-08-16 — v0.1.2 shipped; first external issues)
- [done] v0.1.2: fixes for bermanto's issues #1 (missing/refused refresh → reauth banner; OAuthError now maps to .unauthorized), #2 (AppleDouble-free zip, unzip-verified), #3 (private error descriptions + logCode, source guard), #4 (removed tap gesture racing List selection). #2/#3/#4 closed; #1 open pending his answer on whether offline_access was in the granted scopes #shipped
- [fact] Sparkle self-update from 0.1.0 → 0.1.1 confirmed by the owner; release notes now flow from CHANGELOG.md (see Herald Release Pipeline) #verified
- [todo] Session close 2026-08-16: all work on main (hqbase-mac 09e438d), worktrees removed, scratch cleaned; fork branches docs/native-client-oauth + docs/conversation-action-id retained for open PRs #30/#31; ~/Developer/hqbase checkout belongs to another live session (feat/hqbase-domain-move) — leave it alone #state
