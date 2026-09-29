---
created: 2026-09-29
updated: 2026-09-29
source_sha: 2bfa6bee79e5baf669c80ee8cf23b74d74feaead
source_paths: Herald/Analytics, HeraldKit/Sources/HeraldKit/Notifications
source_paths_inferred: false
---

# Analytics and Notifications

## Analytics: UsageEvent

Herald tracks anonymous, opt-in usage via `swift-stats` (Apple's privacy-respecting analytics library). See [[herald-usage-analytics-swift-stats]].

**UsageEvent** (Swift enum)
- Variants for every major user action: `.compose(kind:)`, `.messageAction(action:scope:)`, `.search(scope:)`, `.syncTriggered(trigger:)`, etc.
- Each carries only structured enum cases, never raw text (subject, sender, body, etc.).
- Logged to the `/Library/Application Support/Herald/UsageEvents` SQLite database.

**Consent model**
- `.all` (default) — track everything; OR `.none` — turn it off completely.
- Set in Settings → Privacy.
- Regenerated per install (never shared across machines).

**Auto-events**
- `.appOpen` — fired on launch.
- `.sessions` — fired every 30 min of active use.
- No `.appBackground` (macOS fires it too often).

## Notifications: NewMailNotifier

**NewMailNotification** (Sendable struct)
- `id`, `mailboxID`, `messageID`, `fromAddress`, `subject`, `timestamp`.
- Converted from a CachedMessage when sync detects new mail.

**NewMailNotifier** (actor)
- Watches for new messages via sync updates.
- Posts to `NewMailNotificationPosting` protocol (allowing fake implementations in tests).
- On macOS, that's `UserNotificationCenterAdapter` (wraps UNUserNotificationCenter).

**NewMailRoute** (Sendable struct)
- Returned when the user clicks a notification; contains the messageID and mailboxID.
- AppEnvironment routes to that message, opens the app if needed.

## When you touch this

- Adding a new usage event? Add a case to UsageEvent, log it with `UsageTracker.track()`, and test that it appears in the database.
- Changing notification sound or grouping? Edit UserNotificationCenterAdapter.post(); test on macOS 15+ (notifications are cached).
- Turning off analytics? Set consent to `.none` in SettingsModel; UsageTracker stops logging new events but keeps old ones (user privacy).
