# UI tests — final audit (2026-09-27)

Plan documents/plans/ui-tests-2026-09-27.md: U1–U5 delivered (harness c292722, refresh CAS fix 05eb4ca, target 67f181d, scenarios b382ba6, banner layout fix + first-run 7d53ef5, Outbox flake 176efc5, time limits b70b54a). Full UI suite 5× green; unit 391 + 444 green. UI tests found a real bug (banner covering sidebar on macOS 27).

## Isolation audit (read-only)
Verdict: test mode cannot reach Release, cannot trigger accidentally (argv-only, Debug-only), fakes everything except AppKit geometry keys and the attachment scratchpad.
- H1 UI tests never verify the launched app is in test mode; `ui-tests.sh "$@"` could pass `-configuration Release` → real Keychain/account. Fix: launch helper requires `uitest.status` else terminate+fail; script refuses `-configuration`.
- M1 `XCUIApplication.launch()` may terminate the running release app (same bundle id). M3 AppKit window/split-view geometry written to the real prefs domain. L1 attachment scratchpad shared + wiped at launch. L2 LaunchServices/notification routing confusion. → Alan chose a separate Debug bundle id (structural fix).
- L3 release.sh has no automated harness-string check. Info: ui-tests.sh and build-detached.sh share DerivedData and pkill the same Debug path.

## Fresh-eyes audit (read-only)
No confirmed production bug in the commits.
- F1 (medium, pre-existing on the CAS line) Keychain failure AFTER a 200 refresh is treated as retryable transport → loop re-spends the rotated refresh token → family invalidation/logout. Fix: separate do/catch; never loop after a 200; serve fresh without persisting.
- F2 dead-session Send test can pass via the 15 s poll (≈1/10) without exercising P2 routing. Fix: harness control to pause the poll (or 401 only /send); assert sendRequests==1 and banner absent before click.
- F3 `openFilledComposer` doesn't wait for autosave to go quiet → pending PATCH can 401 first.
- F4 vacuous assertions (`?? 0` on missing status, "healthy" check without a success counter, autosave check vacuous under latch).
- F5 menu fallback queries whole app (menu-bar duplicates of Add Account / Sign Out).
- F6 fake fidelity gaps: rotated-token reuse (no family invalidation / replay grace), `resource` not validated on refresh, no per-route scopes, 401 body shape.
- F7 banner-up layout shift (split view moves down) → manual look (full screen, sidebar collapsed) → add to checklist v2.

## Follow-up phases
- U6a production & isolation: separate Debug bundle id (+ callback scheme, container, Keychain namespace review, entitlements, scripts, docs), F1, L3, H1 guard, script guards, scratchpad Debug path.
- U6b test quality: F2–F6, F7 into checklist v2, 5× full-suite rerun.
