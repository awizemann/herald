---
id: t-45bafcc3
title: 1.4 F2: compose + signatures UI/security fixes (send-hold reason, preview CSP/tokens/debounce, announcements, @State ownership, logCode)
status: done
added: 2026-09-19
priority: high
---

## Description

Audit report items C3–C9, P1, P3, P7, P8, P9. Files: Herald/Views/SignatureSettingsView, SettingsView, Herald/App/SignatureSettingsModel, Herald/Compose/ComposeWindow + ComposeViewModel, HeraldKit API/AuthenticatingMiddleware (P1 only), MessageRenderingSecurityTests, SignatureSettingsTests, ComposeViewModelTests.

## Plan



## Artifacts

Commit 7cebbf5 on branch `worktree-agent-a24efe66c7b929f73`.

All 12 items landed: C3 C4 C5 C6 C7 C8 C9 P1 P3 P7 P8 P9.

Tests: HeraldKit 347 → 349, app-hosted 276 → 283 (9 new, all discriminating). Both suites green; grep guards clean.

Memory: "Herald Design System and Accessibility" (shared web-document emitter, disabled-control shortcut proxy, announcement counter, sheet sizing), "Herald Send Idempotency and SEND_* Holds" (hold UX), "Herald Signature Handling" (P3 terminal state, save reentrancy, delete title, logCode).

FOLLOW-UP required in AppEnvironment (owned by the F3 split, not touched here):
1. P3 is inert until `signatureSettingsModel()` passes `grantedScopes: { [weak graph] in graph?.account.scopes ?? [] }`. The parameter defaults to `{ [] }` = "unknown", which preserves current behaviour.
2. `forgetSignatureSettings(accountID:)` drops the pane model on a re-auth that replaces the graph, so the `hasRetriedSignIn` latch does not survive one. The granted-scope comparison is the signal that must carry P3; consider keeping the latch per account id in AppEnvironment.
3. `UsagePrivacyModel` should be cached in AppEnvironment beside `signatureSettingsModel()`. Interim fix: `PrivacySettingsPane` now takes the `UsageTracking` seam and builds its model once in `.task`; a TODO marks the spot in SettingsView.swift.

