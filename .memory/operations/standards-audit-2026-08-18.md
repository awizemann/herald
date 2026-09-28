---
title: Standards Audit 2026-08-18
type: note
permalink: hqbase-mac/operations/standards-audit-2026-08-18
tags: [audit, standards]
source_paths: [Herald/Design/MailTheme.swift, Herald/Views/ConversationListView.swift, HeraldKit/Sources/HeraldKit/Sync/MailStore.swift, Herald/App/MailViewModel.swift, HeraldKit/Sources/HeraldKit/Auth/AccountStore.swift, HeraldKit/Sources/HeraldKit/Sync/MailStoreContainer.swift]
source_paths_inferred: false
source_sha: a82a8d7cce5a32c719d4a94f4f07bc68fc504033
created: 2026-08-18
updated: 2026-08-18
reviewed: 2026-09-20
reviewed_by: audit:claude-code (background)
---

## Observations
- [fact] Audited Herald production Swift against the 11 centralized standards at /Users/awizemann/Developer/_standards/ (3 parallel agents: code-quality, storage/security, design/UI); full report documents/reports/standards-audit-2026-08-18.md. Verdict: strong — 0 Critical, 0 High correctness; initial gap was design tokens #audit
- [fact] Compliant/exemplary: no print()/DispatchQueue/@Query-in-views; colors fully tokenized in MailTheme; accessibility (iconButtonStyle bundles hit-frame+help+label); <=1 @State/view; secrets Keychain-only (0 UserDefaults leaks); 22 loggers all subsystem com.wizemann.herald (= bundle id, Apple-idiomatic) #compliant
- [decision] Sanctioned deviations, NOT defects (leave as-is): bare Schema([]) / no VersionedSchema (rebuildable cache); file-scope private nonisolated let logger (Swift 6.2 default-MainActor); no NSFileCoordinator/backup parity (non-iCloud cache); Sparkle ObservableObject/Combine bridge (no @Observable equivalent) #deviations
- [done] P1 gap: MailTheme design tokens — spacing/radius/typography/animation scales implemented in commit 8282ffb; colors + a11y exemplary. Remediation verified at f7ef9a5. Resolved task t-2144407d #tokens
- [done] Follow-ups all completed: MailStore/MailViewModel split under 1000 at f7ef9a5 (t-9f94365e); KeychainAccountStore NSLock→os_unfair_lock at 9df695d (t-e2af8452); hygiene batch at 5526423 (t-47993e16, 4 try? decode comments, TOCTOU, revert-log, force-unwrap) #completed
- [fact] Subsequent feature development (f7ef9a5..HEAD): labels sync, wake socket, drafts, search, notifications, attachments, auth recovery, and R1/R2 redesign phases. Files grew naturally; all audit fixes remain in place #ongoing
- [fact] R1 redesign (commit cbd9c05) significantly expanded design tokens beyond initial audit scope: comprehensive nonisolated Color enum (bg, sidebar, surface, line, ink, accent, select, danger, match, warn, ok, star); AccountTint system (8 account tints with named assets); Wash opacity scales (badge/chip strengths); label colors migrated from system to named assets. All tokens centralized in MailTheme; no hardcoded colors in views. Concurrency rules maintained (nonisolated static for accessibility/search); token system exemplary #designevolution

## Update (2026-08-18 — remediation completed, all findings resolved by f7ef9a5)
- [done] All four findings remediated on main across four commits: 5526423 hygiene (t-47993e16), 8282ffb design tokens (t-2144407d), 9df695d os_unfair_lock (t-e2af8452), f7ef9a5 file split (t-9f94365e). Full remediation verified at f7ef9a5: xcodebuild suite passed (79 app-hosted + 157 kit) and HeraldKit swift test (157 passed), both exit 0. Independent fresh-eyes audit reviewed 5526423..f7ef9a5: verdict correct + regression-free #verified
- [fact] At f7ef9a5 (remediation complete): MailStore 930L + MailViewModel 954L (both <1000), all design tokens on MailTheme (Spacing/Radius/Typography/Animation), NSLock→os_unfair_lock in KeychainAccountStore, hygiene findings cleared #baseline
- [fact] Subsequent evolution (f7ef9a5 to HEAD, 2026-08-18 → 2026-09-27): MailViewModel grew to 2499L and MailStore to 1234L with feature additions (wake socket, drafts, search, auth recovery, notifications, R1/R2 redesign). Design token architecture now exemplary and comprehensive with nonisolated Color enum + AccountTint system + label color migrations. Concurrency model and hygiene fixes remain in place; all audit findings stay resolved #ongoing

## Relations
- relates_to [[Herald Design System and Accessibility]]
- relates_to [[Herald Concurrency Rules]]
- relates_to [[Herald Sync Model]]
