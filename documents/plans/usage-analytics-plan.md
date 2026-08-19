# Herald usage analytics (swift-stats) — approved plan, 2026-08-18

Package: `.package(url: "https://github.com/awizemann/swift-stats", from: "0.1.0")`, products `Stats`, `StatsCloudflare` (app), `StatsTesting` (tests). Backend `https://api.swiftstats.co`. Consent `.all`; autoEvents `[.appOpen, .sessions]` (no `.appBackground`). `installIdSalt = "herald-mac-2026"` (constant, not secret, never change). Info.plist key `HeraldStatsWriteKey` = `$(APP_STATS_WRITE_KEY)`.

## Architecture
- `Herald/Analytics/UsageEvent.swift` — privacy contract enum. Props: closed enums' raw values, bools, coarse buckets only.
- `Herald/Analytics/UsageTracking.swift` — `nonisolated protocol UsageTracking: Sendable { track(_:) async; applicationDidBecomeActive() async; flush() async; setEnabled(_:) async; var isEnabled: Bool { get async } }`, `StatsUsageTracker`, `NoopUsageTracker`, `UsageAnalytics.makeTracker(environment:arguments:writeKey:)` → noop under XCTest / demo-mock flags / missing/empty/`$(...)` key.
- Owner: `AppEnvironment.usage` (injected, default `NoopUsageTracker()`), `record(_:)` chains Tasks for ordering; MailViewModel/ComposeViewModel call through it. Herald deviations: no single store (AppEnvironment + per-account MailViewModel + ComposeViewModel); StatsClient built in `AppEnvironment.init` (no I/O); lifecycle from existing NSApplication didBecomeActive/didResignActive observer; no MenuBarExtra.
- Opt-out: Settings → Privacy tab, "Share anonymous usage" toggle → `setEnabled`. No opted-out event.
- `PrivacyInfo.xcprivacy`: Product Interaction + Other Diagnostic Data, not linked, not tracking, `NSPrivacyTracking` false, UserDefaults CA92.1.

## Buckets
`count`/`results`/`accounts`/`attachments`: `0`, `1`, `2_5`, `6_20`, `20_plus` (count of actions omits `0`).

## Events
| Event | Props | Source |
|---|---|---|
| `view_shown` | `view`: inbox/sent/starred/archived/trash/catchall/drafts/thread; `via`: launch/sidebar/search/notification/shortcut/other | selection didSet, showDrafts, openThread/exitThread, launch |
| `sync_completed` | `trigger`: manual/auto/launch; `changed`: bool | SyncEvent .finished |
| `sync_failed` | `kind` (MailAPIError kind); `trigger` | SyncEvent .failed |
| `message_action_performed` | `action`: read/unread/star/unstar/archive/trash; `scope`: message/conversation/selection; `count` bucket | perform/performOnSelection/toggleStar/toggleRead |
| `action_failed` | `action`; `kind` | actionError path |
| `search_run` | `scope`: local/server; `results` bucket | submitSearch/runServerSearch |
| `search_failed` | `kind` | ServerSearchState .failed |
| `compose_opened` | `kind`: new/reply/reply_all/forward/draft | requestCompose |
| `draft_saved` | — | ComposeViewModel.saveNow ok |
| `message_sent` | `attachments` bucket; `has_cc`; `has_bcc` | send ok |
| `send_failed` | `kind` (OutboxError kind) | send fail |
| `compose_discarded` | — | discard |
| `draft_deleted` | — | deleteDraft |
| `attachment_saved` | — | saveAttachment |
| `remote_media_loaded` | — | trustRemoteMedia |
| `account_added` | `outcome`: success/cancelled/failed; `kind` (OAuthError kind, failed only) | signIn |
| `account_reauthenticated` | `outcome`; `kind` | reauthenticate |
| `account_removed` | — | signOut |
| `account_switched` | `accounts` bucket | selectedAccountID set |
| `notifications_toggled` | `enabled`: bool | notificationsSettingChanged |
| `mailbox_color_changed` | — | setMailboxColorToken |
| `update_check_requested` | — | explicit menu check only |
| `launch_failed` | `kind`: cache/restore/other | phase = .failed |

## Error kinds (explicit switch, payloads dropped; fallback `other`)
- MailAPIError: unauthorized, insufficient_scope, not_found, cursor_expired, server, transport, decoding
- OAuthError: discovery, registration, server, state_mismatch, missing_code, reauth_required, missing_refresh_token, malformed_token, cancelled, web_auth, unknown_account, transport
- OutboxError: invalid_recipient, no_recipients, attachment_too_large, draft_too_large, too_many_attachments, draft_conflict, api_<MailAPIError kind>, file_unreadable

## Never collected
Search text, mailbox/folder names, account origins, subjects, addresses, attachment names/sizes, IDs, bodies, error messages, unread counts, version strings beyond SDK context.

## Opt-out copy
"Share anonymous usage. Sends which features you use (e.g. "archived a message", "opened search") and basic app/OS version info to Herald's developer, tagged with a random per-install identifier so active installs can be counted. Never sent: your mail, subjects, addresses, search text, mailbox names, account details, file names, or anything you type. Turn this off and nothing further is sent, including anything queued."

## Phases / tasks
P1 t-e425c325 · P2 t-dcb470be · P3 t-a73fa929 · P4 t-1a8767ad · P5 t-197c4c10
