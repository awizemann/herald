---
title: Herald Design System and Accessibility
type: note
permalink: hqbase-mac/conventions/herald-design-system-and-accessibility
tags:
- design
- accessibility
- macos
---

## Observations
- [rule] Single source for status→color / folder→symbol (`MailTheme`); one chip component; neutral surfaces as named tokens; no raw Color(hex:) where a token exists (why: dark mode and future theming swap in one place) #tokens
- [rule] Every icon-only button gets .help + .accessibilityLabel AND a ~28pt hit frame with .contentShape(Rectangle()) (why: intrinsic ~18pt icon target is too small) #buttons
- [rule] macOS-first: Full Keyboard Access, menu-bar Commands for every mail action (⌘R reply, ⌘⇧A archive, ⌫ trash, ⌘⇧U unread…), sensible min window size, NavigationSplitView with restorable column widths; unread state pairs bold text + dot, never color alone #macos
- [rule] Don't .id()-reset the reading pane or the conversation list; pass identity as input, key loads with .task(id:), resolve selection by id from the UNFILTERED source (why: id-reset tears down the whole subtree synchronously; filtered-selection re-renders detail on every keystroke) #views
- [rule] Search field is debounced ~250ms into local @State before pushing to the view-model #search

## Relations
- relates_to [[Herald Architecture]]

## Update (2026-08-15 — P0.4 findings)
- [gotcha] WKContentRuleList `url-filter` rejects regex alternation (`^(https?|wss?)://` fails to compile SILENTLY at runtime) — use one rule per plain prefix (`^http`, `^ws`, `^ftp`); `RemoteContentBlockerTests.ruleListCompiles` compiles the JSON in-process to guard this #webkit
- [gotcha] `deinit` of a @MainActor @Observable class is nonisolated and can't touch isolated state — long-lived Tasks need an explicit `stop()` called by the owner (AppEnvironment) #lifecycle
- [fact] Archive/trash: MailStore.applyLocalAction changes the message folder but not the CachedConversation listFolder scope, so MailViewModel filters rows by `latest.folder` (`belongs(_:to:)`) so they vanish immediately #optimistic
- [fact] MailViewModel exposes two @ObservationIgnored reload counters solely so tests can prove "no speculative reload" — the only test instrumentation in the VM #testing

## Update (2026-08-16 — chips + dates)
- [rule] Mailbox tint = `MailboxColorAssignment` (FNV-1a over lowercased address → `MailTheme.mailboxPalette` index; override stored as the token NAME under `mailboxColor.<accountID>.<mailboxID>`); the palette ORDER is a persistence contract — append tints, never reorder. Never use `Hasher`/`hashValue` for anything that must survive relaunch (per-process seeded) #tint
- [rule] Row dates use `RowDateFormatter` (today→time, Yesterday, ≤6d weekday, same-year "Aug 15", else with year) in a fixed 78pt trailing slot with `.help(full)` + a11y value = full date #dates
- [gotcha] Adding a test FILE requires `xcodegen generate` before `xcodebuild test`, or the stale project runs without the new suite and reports a false green #xcodegen
