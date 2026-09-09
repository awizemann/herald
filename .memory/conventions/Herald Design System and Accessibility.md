---
title: Herald Design System and Accessibility
type: note
permalink: hqbase-mac/conventions/herald-design-system-and-accessibility
tags: [design, accessibility, macos]
created: 2026-08-16
updated: 2026-09-04
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


## Update (2026-08-18 — list row heights)
- [gotcha] macOS `List` (NSTableView-backed) caches a measured height per row identity; a freshly inserted row it has not measured is drawn at `defaultMinListRowHeight` (24pt) — a row-level `.frame(minHeight:)`/`.fixedSize` cannot fix a squashed new-mail row because the row's own layout is never consulted. Both lists set `.environment(\.defaultMinListRowHeight, MailTheme.rowMinHeight)` (88 = a full four-line row) #list #rows
- [gotcha] A resolved new message whose mailbox is not yet in `mailboxNames` must trigger a mailbox reload (`MailViewModel.apply`), else its row first renders without the chip and the list caches the shorter row #rows


## Update (2026-08-18 — standards audit)
- [fact] Maps to centralized standard 05 (Design System) at /Users/awizemann/Developer/_standards/. Audit verdict: colors + accessibility EXEMPLARY (fully tokenized, iconButtonStyle a11y bundle, dark-mode-safe) #standards
- [todo] Open gap: MailTheme has NO spacing/radius/typography/animation scales, so ~60 raw spacing literals live across views (off-grid 1,5,6,7; unread-dot drift 8x8 ConversationListView vs 7x7 ReadingPaneView). Add MailTheme.Spacing/Radius/Typography/Animation and migrate — task t-2144407d; see operations/Standards Audit 2026-08-18 #tokens


## Update (2026-08-18 — token scales landed, commit 8282ffb)
- [rule] MailTheme now carries the spacing/radius/typography/animation scales. New UI reads from them — no raw spacing/padding/radius/font-size/animation literals where a token fits. Scale: MailTheme.Spacing (4pt grid xxs2/xs4/sm8/md12/lg16/xl20/xxl24/xxxl32), MailTheme.Radius.sm(6), MailTheme.Typography.heroGlyph/largeGlyph (the two display glyphs; everything else stays on Apple semantic styles), MailTheme.Animation.quick (reduce-motion gate stays at the call site), MailTheme.unreadDotDiameter(8) #tokens
- [fact] Migration ruling was clean-4pt-grid AUTO-SNAP (1→2, 5→4, 6→8, 10→12, ties round up; ≤2px shift accepted); spacing:0 and structural frames (window/min sizes, maxWidth:.infinity, fixed widths, rowMinHeight) stay bare literals #tokens


## Update (2026-09-04 — reading-pane web tokens, P4)
- [convention] The reading pane's WKWebView cannot use SwiftUI `Color`, so its colours live in `MailTheme.Web.light`/`.dark` (foreground/secondary/background/link/quoteBars/quoteSurface as CSS strings) and are mirrored into CSS custom properties by `MailViewModel+HTMLAssembly`. New reading-pane CSS reads a var, never a literal colour #tokens
- [convention] Dark mode in the pane is normalization, NOT inversion: the tokens style the document's own unstyled regions, links, nested-blockquote bars and the quoted-history disclosure; a sender's declared colours and backgrounds are left alone (inverting designed HTML email wrecks it more often than it rescues it) #darkmode
- [fact] `MailTheme.Web` members are `nonisolated` — MailTheme is default-MainActor, and the HTML assembly is `nonisolated static` so it can run off the main actor #concurrency


## Update (2026-09-04 — label chips, P8)

- [rule] Label colour comes from `MailTheme.labelTint(for: LabelColor)` — a translation table from the SERVER's ten closed colour names onto `NSColor.system*` (amber→systemYellow, gray→systemGray). Unlike `mailboxPalette` its order is NOT a persistence contract: the server owns the names, and an unknown one falls back to gray rather than failing the list #tokens
- [rule] `LabelChip`/`LabelChipRow` follow the `MailboxChip` rule exactly — the NAME is always drawn, the tint is only a second cue, and the chips are `accessibilityHidden` because the label names ride in the row's combined summary (`LabelChipRow.accessibilityPhrase` → "labelled Billing, Later"). A conversation row shows at most `MailTheme.maxRowLabelChips` (3) and collapses the rest to "+n"; the reading pane shows all of them #chips
- [gotcha] The label index must be loaded BEFORE the conversation rows are published, for the same NSTableView reason as the mailbox chip: a row first measured without its chip line stays clipped when the chips arrive #rows


## Update (2026-09-04 — a11y fixes A2, t-324c17aa)

- [rule] CHIP RULE, AMENDED: a tinted chip draws its NAME in `MailTheme.chipLabelForeground` (`.primary`), never in the tint — a caption2 name in systemYellow/orange/teal over an 18% wash of the same tint misses WCAG AA in light mode. The tint now carries the FILL (`mailboxChipFillOpacity` 0.18) plus a hairline border (`MailTheme.chipBorderOpacity` 0.55), which is what keeps two chips of different colours apart once the text is neutral. Applies to `LabelChip` and `MailboxChip`; `MailboxChip`'s untinted fallback keeps `attributionForeground` on the neutral surface #chips #tokens
- [rule] A menu that carries SELECTION uses `Toggle` rows (`LabelMenu`/`MessageLabelMenu`/the compose signature menu) — a hand-drawn `Label(systemImage: isSelected ? "checkmark" : "")` is visual-only AND an empty-string SF Symbol is undefined behaviour. A Menu of rows (not a Picker) whenever ONE row must be disabled; a disabled row's label states its own reason ("… (no longer available)"), because VoiceOver announces "dimmed" without ever saying why #menus
- [rule] A control whose accessibility VALUE repeats its own label view needs `.accessibilityElement(children: .ignore)` before `.accessibilityLabel`/`.accessibilityValue`, or the value is read twice (compose signature menu) #a11y
- [rule] A banner that appears, or swaps state, under a cursor that is not on it POSTS `AccessibilityNotification.Announcement` — ReauthBanner (both states; the manual announcement NAMES the Sign In button, since the automatic state withdraws it out from under the cursor), the reading pane's remote-image-consent and inline-image-failure banners, and the search status bar. Announce, don't force focus: yanking the cursor to an unrequested banner is worse than the dropped button. Search announces SETTLED states only (`SearchStatusBar.announces`) — the bar's text also changes on every debounced keystroke #a11y
- [rule] Banner strings live as `nonisolated static` funcs beside the view (`ReauthBanner.message/announcement`, `MessageBodySection.remoteConsentText/inlineImageFailureText`) — one source for what is DRAWN and what is SPOKEN, and assertable without a rendered view (the `accessibilitySummary`/`accessibilityPhrase` pattern). A `BannerView`'s icon is `accessibilityHidden` — the text says everything the glyph does #a11y
- [rule] Reading-pane CSS honours Increase Contrast: `@media (prefers-contrast: more)` overrides ONLY `--secondary`/`--link` from `MailTheme.Web.Palette.secondaryIncreasedContrast`/`linkIncreasedContrast`, emitted per appearance and AFTER the dark palette block (equal specificity — order decides). The base palette already clears AA; the rest of the pane is the sender's own colours, untouched at any contrast setting #tokens #webkit
