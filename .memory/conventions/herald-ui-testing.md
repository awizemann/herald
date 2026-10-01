---
title: Herald UI Testing
type: note
permalink: hqbase-mac/conventions/herald-ui-testing
tags: [testing, uitest, xcuitest]
source_paths: [Herald/UITestSupport, HeraldUITests, scripts/ui-tests.sh, scripts/verify-release-identity.sh, Herald/Support/AccessibilityID.swift, project.yml, HeraldTests/UITestHarnessTests.swift, HeraldTests/DebugIdentityTests.swift]
source_paths_inferred: false
source_sha: 2d441e9a9ad57500bef916f829b4ad0b9934e258
created: 2026-09-27
updated: 2026-09-28
reviewed: 2026-09-29
reviewed_by: audit:claude-code (background)
---

## Observations
- [constraint] UI tests take over Alan's mouse, keyboard and screen: never start a UI-test run (scripts/ui-tests.sh) without his explicit go #uitest #running
- [invariant] UI-test mode exists only in Debug (Herald/UITestSupport is all #if DEBUG) AND only with -HeraldUITest <scenario>; a malformed request fatalErrors instead of falling back to the real Keychain/network #uitest #isolation
- [invariant] Three launch guards: ui-tests.sh refuses identity-changing args and any build not com.wizemann.herald.debug; HeraldApp.launch terminates an app that does not draw uitest.status within 20 s; verify-release-identity.sh keeps harness strings and Debug ids out of release builds #uitest #isolation
- [convention] Assertions are never vacuous: XCTUnwrap status fields (never ?? 0), 'healthy' means a success counter moved (apiSuccesses), 'did not happen under a latch' uses an app-side attempt counter (saveAttempts); each is mutation-checked #uitest #discriminating
- [fact] Status 2026-09-28: 12 tests in 4 classes; 5x consecutive runs 12/12 after U6b (t-23673507 closed); suite infrastructure now supports draft and attachment testing via .oneAccountWithDrafts scenario #uitest #status

## Relations
- relates_to [[Herald Testing Conventions]]
- relates_to [[Herald Build and Toolchain]]
- relates_to [[Sign-In Recoverability and the Presentation Watchdog]]
- relates_to [[Herald Architecture]]
- relates_to [[HQBase Mail API v1 Contract]]
