---
title: Standards Audit 2026-08-18
type: note
permalink: hqbase-mac/operations/standards-audit-2026-08-18
tags: [audit, standards]
source_paths: [Herald/Design/MailTheme.swift, Herald/Views/ConversationListView.swift, HeraldKit/Sources/HeraldKit/Sync/MailStore.swift, Herald/App/MailViewModel.swift, HeraldKit/Sources/HeraldKit/Auth/AccountStore.swift, HeraldKit/Sources/HeraldKit/Sync/MailStoreContainer.swift]
source_paths_inferred: false
source_sha: 25b552c1afd3ef7bdb6f490aec75f4ceb7ad7ae7
created: 2026-08-18
updated: 2026-08-18
---

## Observations
- [fact] Audited Herald production Swift against the 11 centralized standards at /Users/awizemann/Developer/_standards/ (3 parallel agents: code-quality, storage/security, design/UI); full report documents/reports/standards-audit-2026-08-18.md. Verdict: strong — 0 Critical, 0 High correctness; single systemic gap is design tokens #audit
- [fact] Compliant/exemplary: no print()/DispatchQueue/@Query-in-views; colors fully tokenized in MailTheme; accessibility (iconButtonStyle bundles hit-frame+help+label); <=1 @State/view; secrets Keychain-only (0 UserDefaults leaks); 22 loggers all subsystem com.wizemann.herald (= bundle id, Apple-idiomatic) #compliant
- [decision] Sanctioned deviations, NOT defects (leave as-is): bare Schema([]) / no VersionedSchema (rebuildable cache); file-scope private nonisolated let logger (Swift 6.2 default-MainActor); no NSFileCoordinator/backup parity (non-iCloud cache); Sparkle ObservableObject/Combine bridge (no @Observable equivalent) #deviations
- [todo] P1 gap: MailTheme has no spacing/radius/typography/animation scales -> ~60 raw spacing literals, off-grid values (1,5,6,7), 8x8-vs-7x7 unread-dot drift -> task t-2144407d (high). Colors + a11y already exemplary #tokens
- [todo] Follow-ups: split MailStore(1254)+MailViewModel(1183) under 1000 (t-9f94365e); KeychainAccountStore NSLock->actor (t-e2af8452); low-risk hygiene batch t-47993e16 (4 try? decode comments, TOCTOU MailStoreContainer:97-99, revert-log MailActionService, drop constant force-unwrap) #followups

## Relations
- relates_to [[Herald Design System and Accessibility]]
- relates_to [[Herald Concurrency Rules]]
- relates_to [[Herald Sync Model]]


## Update (2026-08-18 — remediation landed, all four tasks done)
- [done] All four findings remediated on main, sequential phases (one Opus sub-agent each: edit → build → both suites → self-audit; orchestrator audited each diff + committed). Commits: 5526423 hygiene (t-47993e16), 8282ffb design tokens (t-2144407d), 9df695d os_unfair_lock (t-e2af8452), f7ef9a5 file split (t-9f94365e). Baseline d8d5867 committed the prior uncommitted debug-namespace + row-height work first for a clean tree #done
- [fact] Authoritative final gate on HEAD f7ef9a5: xcodebuild app suite ** TEST SUCCEEDED ** (79 app-hosted + 157 kit) and HeraldKit swift test 157 passed, both exit 0. Detection greps clean: no print/NSLock/force-unwrap-URL/TOCTOU/leftover-spacing-literal; MailStore 930 + MailViewModel 954 (both <1000) #verified
- [fact] Independent fresh-eyes audit (agent that did none of the work) reviewed 5526423..HEAD: verdict correct + regression-free. Token bodies byte-identical on the split, reverts still best-effort, lock serializes every index RMW. Only nit: the split commit message undercounted promotions (fixed by amend — 17 private->internal, none public) #audit
- [decision] Phase 3 ruling: NSLock -> os_unfair_lock (OSAllocatedUnfairLock), NOT actor — see Herald Concurrency Rules; the sync nonisolated AccountStore protocol forbids an async impl #ruling
- [todo] Not committed by this session (left for Alan): CLAUDE.md + AGENTS.md Standards-section updates (entangled with the pre-existing memophant shim regen); managed tiers (this note, design/concurrency notes, TASKS.md) per the usual Memophant per-tier bar #handoff
