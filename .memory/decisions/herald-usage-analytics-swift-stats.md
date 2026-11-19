---
title: Herald Usage Analytics (swift-stats)
type: note
permalink: hqbase-mac/decisions/herald-usage-analytics-swift-stats
tags: [analytics, privacy, swift-stats, release]
source_paths: [Herald/Analytics/UsageEvent.swift, Herald/Analytics/UsageTracking.swift, Herald/App/AppEnvironment.swift, Herald/App/MailViewModel.swift, HeraldTests/Analytics/UsageInstrumentationTests.swift, scripts/release.sh, project.yml, Herald/PrivacyInfo.xcprivacy]
source_paths_inferred: false
source_sha: 54ed13ac9775487fef938169371cd8d8f7913aa9
created: 2026-08-18
updated: 2026-10-06
reviewed: 2026-10-06
reviewed_by: audit:claude-code (background)
---

Herald ships privacy-first, opt-out usage analytics via swift-stats 0.1.0 (hosted https://api.swiftstats.co), landed 2026-08-18 in commit b9bad49. The approved event/prop contract lives in documents/plans/usage-analytics-plan.md and is enforced in code by Herald/Analytics/UsageEvent.swift (the privacy contract) plus HeraldTests/Analytics.

## Observations
- [decision] Consent is `.all` (hashed random install id, salt `herald-mac-2026`, never change), autoEvents [.appOpen, .sessions] — no .appBackground because macOS fires it on every ⌘-tab #analytics
- [decision] One owner: AppEnvironment.usage (injected, never a singleton); record(_:) is synchronous via the SDK's record() (see 2026-10-06 update — the old Task chain is gone); action methods on MailViewModel/ComposeViewModel are instrumented, never buttons (exception: setting_changed, below); view_shown consumes the pending `via` before the equality guard; the launch view is emitted once per PROCESS (2026-10-06) #analytics
- [constraint] The write key never enters the repo: Info.plist is xcodegen-GENERATED from project.yml `info.properties`, so `HeraldStatsWriteKey: $(APP_STATS_WRITE_KEY)` is declared there as a reference only; release.sh requires APP_STATS_WRITE_KEY and supplies it via a 0600 temp xcconfig (not argv — xcodebuild echoes argv), regenerates with `env -u`, and asserts the exported plist + bundled PrivacyInfo.xcprivacy; dev builds resolve to "" → NoopUsageTracker #release
- [gotcha] swift-stats keeps opt-out/consent/seq in a UserDefaults suite named from appId alone (com.wizemann.stats.<appId>), and HeraldTests run inside the sandboxed host — tests must use unique appIds or they poison the production suite; also `xcodebuild test` in a derivedData dir rebuilds the app WITHOUT the key, so rebuild keyed before an E2E launch #testing
- [fact] E2E verified 2026-08-18: keyed build → real install UUID, seq advanced, queue.jsonl drained to 0 bytes on 202, props as designed; error kinds have an `other` fallback and non-MailAPIError failures are recorded as such, never dropped #analytics

- [fact] 2026-08-19: bumped to swift-stats 0.2.0 (project.yml `from: 0.2.0`). Upstream CHANGELOG: no breaking Swift API; additive `record()`/`drainRecorded()`/`URLSessionTransport.defaultConfiguration()`. Behaviour deltas that touch Herald: batches stay queued under Low Data Mode (default `allowsConstrainedNetworkAccess=false`), 20s/60s timeouts, additive `queue.head` sidecar, memory-only fallback after 3 disk failures. Herald uses none of the changed init paths (default transport, SDK-created storage dir in prod; tests pass `storageDirectory`, which is now no longer re-moded 0700 — fine for temp dirs). Full build + 196 tests green. Not adopted: `record()` — AppEnvironment already orders via its own Task chain; revisit only if a simplification is wanted #analytics


## Relations
- relates_to [[Herald Release Pipeline]]
- relates_to [[Herald Testing Conventions]]
- relates_to [[Herald Architecture]]


## Update (2026-09-04)
- [fact] `UsageTracking` gained `isAvailable` (false on NoopUsageTracker): Settings → Privacy disables the toggle with "Usage analytics aren't included in this build" in unkeyed builds (the toggle used to render live-but-off and snap back — reported as a no-op), and keyed builds now show a brief confirmation caption after opt-in/out. `accountReauthenticated` gained an `automatic` prop to separate machine re-auth attempts from the human funnel #toggle


- [decision] 2026-09-28 (commit a78106a): `mailbox_color_changed` removed from the vocabulary (never emitted since per-mailbox colours went). Added `scope_changed(to: all_domains|domain|mailbox, via: UsageViewTrigger)` — `UsageScopeKind` closed enum, kind only, no ids. Emitted in `MailViewModel.navigate(to:)` when scope changes and `reportsView` is true (so silent stale-scope corrections are not reported), recorded just before the `view_shown` it produces. Fixture discriminant 20 reused. Coverage: account switching = `account_switched` (AppEnvironment.selectedAccountID didSet, account popover path); folder changes = `view_shown`. Tests: `UsageScopeChangeTests` in UsageInstrumentationTests.swift.



## Update (2026-10-05) — swift-stats 0.3.0
- [fact] Pinned `minorVersion: 0.3.0` in project.yml (up-to-next-MINOR — 0.x minors may break; never `from:`). Resolved to tag commit df9a926. 0.3.0 upgrade notes 2a–2h were checked against Herald: consent was already `.all` (= 0.3.0 `.default`), so install metrics see NO data break; Herald never calls `setConsent`/`identify`, builds one client, already awaited `isEnabled`, and uses no `ManualClock` #analytics
- [correction] Herald collected a stable install id (Device ID) since 0.1/0.2 — `.all` included `.identity` there too — but `PrivacyInfo.xcprivacy` did not declare it until 2026-10-05. Now declared: Device ID, not linked, not tracking, purpose Analytics (matches the SDK's own 0.3.0 manifest). Guarded by `UsageIdentityTests.privacyManifestDeclaresExactlyWhatTheSDKCollects` #privacy
- [decision] Sync passes (`sync_completed`/`sync_failed`) are reported ONLY while `MailViewModel.isAppActive` (`recordSyncPass`). swift-stats' `track()` opens a session on any event, so the 60s background poll made an unattended Mac look in use (setup guide §4 "Unattended work"). The gate is read when the event is CONSUMED; a dropped pass still consumes its trigger, so a hidden launch reports no `launch` pass #analytics
- [decision] `AppEnvironment.start()` records `applicationDidBecomeActive` itself when the app is already active — a foreground cold launch posts didBecomeActive before `RootView.task` subscribes, so `app_open` was never sent on launch before this. SDK call is idempotent within a session #lifecycle
- [gotcha] The `willTerminate` flush must NOT hop to the main actor (main thread is inside `terminate:` → `exit()`); it captures the Sendable tracker and calls `flush()` directly, best-effort. No `applicationDidEnterBackground()` on macOS — Herald has no `.appBackground` #lifecycle
- [rule] Settings › Privacy copy and README must list the guide §7 batch context (app version+build, macOS version, Mac model — never its name — processor type, language and region). Never put the device under "never". "Anonymous" holds only while Herald never calls `identify`. Test: `explanationDisclosesTheBatchContext` #privacy
- [fact] `UsageAnalytics.configuration(sink:)` is the single source of the shipping configuration; `UsageIdentityTests` runs it through `RelaunchProbe` (stable installId across relaunch; control with `[.usage, .diagnostics]` changes it) #testing
- [open] `launchFailed` still records regardless of activation (rare; a hidden launch that fails opens one session). The launch `view_shown` is now gated — see the 2026-10-06 update #analytics



## Update (2026-10-06) — event-quality pass (commits 53b4a77, 6c9cede, 6914194, df25823)
- [correction] The 2026-10-05 sync gate was not enough: while Herald was FRONTMOST every 15s pass still sent `sync_completed`, and swift-stats measures its 30-min session gap from the last event of ANY kind — sessions never closed on an idle, locked Mac. Rule now (MailViewModel.recordSyncPass): report `launch`/`manual` passes; an `auto` pass only on the first failure of an outage the person is around for (`outageReported`, cleared by any success — so an overnight outage is reported once they're back); nothing while inactive. `search_run.server_results` = rows the server tier ADDED after refilter. `draft_kept` is never reported from `flushAndStop` (a rebuild disappears without closing). `launchReportPending` is cleared when the restore ends, so a launch where nothing came up leaves no claim for a later sign-in #analytics
- [decision] Launch is reported ONCE per process: `AppEnvironment.launchReportPending` (set by restoreAccounts) is claimed by the first install → `MailViewModel.reportsLaunch`; others report no launch view and no `launch` sync trigger. Launch view only while active #analytics
- [decision] Emission is `UsageTracking.record(_:)` (sync) → `StatsClient.record()`; the old `enqueueUsage` Task chain is gone (it put each flush — up to 60s on the network — in front of later events and app_open). Lifecycle calls run via `runLifecycle` (start immediately; linked only for `drainPendingUsage`). Tests: `RecordingUsageTracker` is a lock-backed class; use `MailViewModel.syncEventsConsumed` as an ordering barrier, never analytics events #analytics #testing
- [decision] Vocabulary changes: `search_run(local_results, server_results?)` once per Return (auto search silent); `message_action_performed` requires `via` (toolbar/row/context_menu/menu/keyboard/reading_pane/bulk), `scope` is message|conversation only; `draft_kept(via: closed|save_button)` replaced `draft_saved`; `attachment_saved(count, all)`; `compose_opened` from `prepareCompose`; `notification_opened(landed)` is THE banner-click count (no account_switched/inbox view for it); `account_added` kinds `invalid_origin`/`already_added` + `accounts` bucket; new `label_changed`, `setting_changed(UsageSetting, on?)`, `notification_permission_resolved` #analytics
- [decision] `setting_changed` is recorded from each setting's single write path (Settings binding or AppEnvironment setter) via `AppEnvironment.recordSettingChanged` — a deliberate exception to "instrument model methods, not buttons", because each setting has exactly one write path. Never the value, domain or account; excludes the usage opt-out, notifications and per-keystroke text fields #analytics #privacy
- [rule] Debug builds never report unless `HeraldSendsDebugUsage` is set (`defaults write com.wizemann.herald.debug HeraldSendsDebugUsage -bool YES`); build-detached.sh scrubs APP_STATS_WRITE_KEY #release
- [fact] Plan of record rewritten: documents/plans/usage-analytics-plan.md (full event table) #analytics
