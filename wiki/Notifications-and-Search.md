---
created: 2026-08-19
updated: 2026-08-19
source_sha: 35ba57be0606d427a5aa36e1500b7f685b444351
source_paths: HeraldKit/Sources/HeraldKit/Notifications, Herald/Support
source_paths_inferred: false
---

# Notifications and Search

Herald watches for new mail and posts macOS notifications. Search is instant local filtering (conversations) plus server-side search (messages).

## New-mail notifications

`NewMailNotifier` (`HeraldKit/Sources/HeraldKit/Notifications/NewMailNotifier.swift:21`) is an actor that:

- Observes `MailStore` for new messages
- Filters by user preference (Settings → Notifications) and suppresses the first sign-in and first mailbox listing so a fresh install is not flooded
- Posts a `NewMailNotification` via the `NewMailNotificationPosting` protocol

`UserNotificationCenterAdapter` (`Herald/Support/UserNotificationCenterAdapter.swift:13`) implements the protocol and posts to the macOS Notification Center via `UNUserNotificationCenter`.

Many arrivals at once are grouped into one banner. Clicking a banner switches to the right account and opens the conversation.

## Dock badge

The dock badge (red circle with unread count) is managed by `DockBadge` (`Herald/Support/NotificationSettings.swift:28`), which calls `NSApp.dockTile.badgeLabel` when unread count changes.

## Search

Herald has two search modes:

1. **Local search** (instant) — As you type, rows are filtered across subject, sender, recipients, and cached body text. ⌘F focuses the field; clearing it takes effect immediately.
2. **Server search** — Return (or a thin local result) asks the server for the current mailbox and folder, with a status line for progress, count, or offline. Server-only results can be opened and acted on like any other row.

Search highlighting is handled by `SearchHighlighter` (`Herald/Design/SearchHighlighter.swift:12`), which marks matching text in results.

---
_Last updated: 2026-08-19 — notifications and search; fact-checked against the code for v0.3.0_