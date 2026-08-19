---
title: Herald Usage Analytics (swift-stats)
type: note
permalink: hqbase-mac/decisions/herald-usage-analytics-swift-stats
tags: [analytics, privacy, swift-stats, release]
source_paths: [Herald/Analytics/UsageEvent.swift, Herald/Analytics/UsageTracking.swift, Herald/App/AppEnvironment.swift, scripts/release.sh, project.yml, Herald/PrivacyInfo.xcprivacy]
source_paths_inferred: false
source_sha: b9bad49ec091e681d0c39a29f1cdb3ab45b3d234
created: 2026-08-18
updated: 2026-08-19
---

Herald ships privacy-first, opt-out usage analytics via swift-stats 0.1.0 (hosted https://api.swiftstats.co), landed 2026-08-18 in commit b9bad49. The approved event/prop contract lives in documents/plans/usage-analytics-plan.md and is enforced in code by Herald/Analytics/UsageEvent.swift (the privacy contract) plus HeraldTests/Analytics.

## Observations
- [decision] Consent is `.all` (hashed random install id, salt `herald-mac-2026`, never change), autoEvents [.appOpen, .sessions] — no .appBackground because macOS fires it on every ⌘-tab #analytics
- [decision] One owner: AppEnvironment.usage (injected, never a singleton); record(_:) chains Tasks for ordering; action methods on MailViewModel/ComposeViewModel are instrumented, never buttons; view_shown consumes the pending `via` before the equality guard and the launch view is emitted exactly once (start() or SidebarView restore, whichever is first) #analytics
- [constraint] The write key never enters the repo: Info.plist is xcodegen-GENERATED from project.yml `info.properties`, so `HeraldStatsWriteKey: $(APP_STATS_WRITE_KEY)` is declared there as a reference only; release.sh requires APP_STATS_WRITE_KEY and supplies it via a 0600 temp xcconfig (not argv — xcodebuild echoes argv), regenerates with `env -u`, and asserts the exported plist + bundled PrivacyInfo.xcprivacy; dev builds resolve to "" → NoopUsageTracker #release
- [gotcha] swift-stats keeps opt-out/consent/seq in a UserDefaults suite named from appId alone (com.wizemann.stats.<appId>), and HeraldTests run inside the sandboxed host — tests must use unique appIds or they poison the production suite; also `xcodebuild test` in a derivedData dir rebuilds the app WITHOUT the key, so rebuild keyed before an E2E launch #testing
- [fact] E2E verified 2026-08-18: keyed build → real install UUID, seq advanced, queue.jsonl drained to 0 bytes on 202, props as designed; error kinds have an `other` fallback and non-MailAPIError failures are recorded as such, never dropped #analytics

- [fact] 2026-08-19: bumped to swift-stats 0.2.0 (project.yml `from: 0.2.0`). Upstream CHANGELOG: no breaking Swift API; additive `record()`/`drainRecorded()`/`URLSessionTransport.defaultConfiguration()`. Behaviour deltas that touch Herald: batches stay queued under Low Data Mode (default `allowsConstrainedNetworkAccess=false`), 20s/60s timeouts, additive `queue.head` sidecar, memory-only fallback after 3 disk failures. Herald uses none of the changed init paths (default transport, SDK-created storage dir in prod; tests pass `storageDirectory`, which is now no longer re-moded 0700 — fine for temp dirs). Full build + 196 tests green. Not adopted: `record()` — AppEnvironment already orders via its own Task chain; revisit only if a simplification is wanted #analytics


## Relations
- relates_to [[Herald Release Pipeline]]
- relates_to [[Herald Testing Conventions]]
- relates_to [[Herald Architecture]]
