# UI audit fix list (SwiftUI + a11y + perf), verified by orchestrator — apply all

Each item: fix + a discriminating test where the behavior is testable off-screen (VM/pure logic).

## Data-loss / correctness (must)
1. **Compose VM lifetime**: keep `ComposeViewModel` in `AppEnvironment.composeViewModels[id]` and return the same instance idempotently from `makeComposeViewModel(id:)`; remove only when `isClosed`. Add `.restorationBehavior(.disabled)` on `ComposeScene` (drafts live on the server; no relaunch restore in P0). Test: two calls return the same instance.
2. **Title-bar close of compose loses the pending autosave**: add a small NSViewRepresentable `WindowCloseInterceptor` that grabs `view.window`, sets a delegate whose `windowShouldClose` calls `requestClose()` and returns false when `hasUnsavedChanges`; on genuine close call a `flushAndStop()` (awaits `saveNow()` if dirty, then stops) instead of `stop()`. Test: VM with a pending autosave — `flushAndStop()` saves once; `stop()` alone would not.
3. **After-save merge**: `saveNow()` must merge only server-owned fields (serverDraft id/version/attachments) into the draft — never overwrite to/cc/bcc/subject/body from the response — otherwise a normalizing server causes an autosave loop. Test: fake outbox returns a draft with a different body; local text unchanged and not dirty.
4. **Selection advances after archive/trash**: in `reloadAfterAction` capture the removed thread's index in the presented list and select the following row (or previous at end) after reload. Test: archive middle row → selection == the next row.
5. **Shortcut collisions**: remove ⌘⇧K from the toolbar Refresh button (menu owns it); remove the bare `e` toolbar shortcut and the bare ⌫ command — implement `e` and ⌫ via `.onKeyPress` on the conversation `List` (focus-scoped, so typing in search is unaffected); Trash menu item gets ⌘⌫ like Mail. Keep ⌘⇧A Archive.
6. **Commands enablement**: verify empirically whether `@FocusedValue` of the observable VM re-evaluates menu enablement on macOS 26 (build+launch, select a row, open Message menu). If not reliable, publish primitive focused scene values (`selectedThreadID`, `selectedMessageID`, `selectedIsUnread`, `selectedIsStarred`) from `MailWindow` and drive `disabled`/titles from those. Report what you observed.
7. **Scene-phase cadence flap**: drive sync cadence from app-level `NSApplication.didBecomeActiveNotification/didResignActiveNotification` (via `NotificationCenter.default.notifications(named:)` in a Task) instead of per-window scenePhase, so opening a compose window doesn't flip to idle.

## Accessibility (must)
8. **Conversation row VoiceOver**: wrap the text VStack in `.accessibilityElement(children: .combine)` with `.accessibilityLabel(accessibilitySummary)` (must include "unread"/"starred"/"has attachments") and `.accessibilityValue(date)`; keep the star as its own element; add `.accessibilityAction(named:)` for Star/Unstar, Archive, Trash on the row. Make `accessibilitySummary` internal + test it contains "unread" and "starred" when applicable.
9. **Thread message rows**: turn the tap-gesture HStack into a `Button(.plain)` (focusable, isButton, isSelected trait) with `.accessibilityValue("Unread")` when unread; arrow keys via `.onKeyPress(.upArrow/.downArrow)` on the container to move `selectedMessageID`.
10. **Web view**: `webView.setAccessibilityLabel("Message body")` in makeNSView; add `<title>` (subject) and `<html lang>` to the wrapping and failure documents.
11. **Compose fields**: move the invalid-address hint to `.accessibilityHint` on the TextField (keep visual text); post `AccessibilityNotification.Announcement` when the error bar appears. Remove `.commandsRemoved()` from the compose scene (compose windows must appear in the Window menu).
12. **Sidebar menu**: put `.help`/`.accessibilityLabel` on the `Menu` itself, not the label image.
13. **Contrast**: `SyncStatusLabel` failed state — bold + `Color(nsColor: .systemRed)`; keep the text label. Selection highlight in MessageHeaderRow: add a 1pt accent border when `accessibilityDifferentiateWithoutColor` is on.

## Performance
14. **`MailViewModel.conversations`** becomes stored (`presentedConversations`), recomputed only in didSet of `allConversations` / `searchQuery` / `selection`, with lowercased search fields computed once per row. Test: instrument a filter counter; N unrelated VM changes → 0 refilters; one search change → 1.
15. **`MessageWebView.updateNSView`** compares (messageID, blocksRemote, contentHash) not the full HTML string; set `loaded` only after `loadHTMLString` is issued; on nil rule list set `loaded = nil` so a retry works.
16. **`reloadUnreadCounts`**: add `MailStore.unreadCount(accountID:mailboxID:)` using `fetchCount` with a #Predicate on readAt == nil (readAt is optional Date — if #Predicate on optional is unreliable, store a Bool `isUnread` mirror on CachedConversation maintained in upserts) and use it. Test: count matches seeded rows.
17. Hoist the per-row `Date.FormatStyle` in `MessageHeaderRow` to a static; fetch inline images with a task group.
18. Remove the unused `sidebarWidth`/`listWidth` @AppStorage; pass only `subject` into `ThreadHeader`; extract one `AttachmentChip` view + `MailTheme.chipBackground`/`selectionHighlight` tokens (replace the raw `Color.accentColor.opacity(0.12)` and repeated `.quaternary`).

Deferred: Keychain reads off main; ⌘F search focus (nice-to-have; add if trivial via `.searchFocused`).
