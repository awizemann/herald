# Herald usage analytics (swift-stats) — plan of record

Approved 2026-08-18; revised 2026-10-06 (swift-stats 0.3.0 upgrade and the event-quality pass: commits 36c1aff, 53b4a77, 6c9cede, 6914194 and the P4 commit). The code is the authority: `Herald/Analytics/UsageEvent.swift` is the complete list of what can be sent, and `HeraldTests/Analytics/UsageEventContractTests.swift` pins every name, prop and value.

Package: `swift-stats` pinned `minorVersion: 0.3.0` (up to next minor — 0.x minors may break), products `Stats`, `StatsCloudflare` (app), `StatsTesting` (tests). Backend `https://api.swiftstats.co`. Consent `.all` (= 0.3.0 `.default`: usage + diagnostics + identity), never `setConsent`, never `identify`. autoEvents `[.appOpen, .sessions]` (no `.appBackground`). `installIdSalt = "herald-mac-2026"` (constant, not secret, never change). Info.plist key `HeraldStatsWriteKey` = `$(APP_STATS_WRITE_KEY)`.

## Architecture
- `UsageEvent.swift` — the privacy contract. Props are closed-enum raw values, bools or coarse buckets only.
- `UsageTracking.swift` — `nonisolated protocol UsageTracking: Sendable { record(_:) (sync); applicationDidBecomeActive() async; flush() async; setEnabled(_:) async; isEnabled { get async }; isAvailable }`. `StatsUsageTracker` forwards to `StatsClient.record()` (time stamped at the call, order kept by the SDK). `UsageAnalytics.configuration(sink:)` is the one shipping configuration. `makeTracker` returns the no-op under tests, the UI-test flag, a missing/empty/`$(...)` key, a bad endpoint, or a Debug build without `HeraldSendsDebugUsage`.
- Owner: `AppEnvironment.usage` (injected; one client per process). `record(_:)` is synchronous; lifecycle calls (activation, flush) start immediately, never behind each other.
- Lifecycle: `NSApplication` didBecomeActive → `applicationDidBecomeActive`; `start()` also calls it when the app is already active (a foreground cold launch posts the notification before Herald listens); didResignActive → flush; willTerminate → best-effort flush. No `applicationDidEnterBackground` on macOS.
- Unattended work is never reported: automatic sync passes, classification, the wake socket, Sparkle's scheduled checks. Sync passes and the launch view report only while Herald is the active app.
- Opt-out: Settings › Privacy "Share anonymous usage" → `setEnabled`. Toggling it records nothing.
- `PrivacyInfo.xcprivacy`: Product Interaction, Other Diagnostic Data, Device ID — not linked, not tracking; `NSPrivacyTracking` false; UserDefaults CA92.1.

## Buckets
`count` / `results` / `local_results` / `server_results` / `accounts` / `attachments`: `0`, `1`, `2_5`, `6_20`, `20_plus`.

## Events
| Event | Props | When |
|---|---|---|
| `view_shown` | `view`: inbox/sent/starred/archived/trash/catchall/drafts/thread; `via`: launch/sidebar/search/notification/shortcut/other | a navigation; the launch view ONCE per process, for the restored account, only while active |
| `scope_changed` | `to`: all_domains/domain/mailbox; `via` | the window's scope moved (not silent corrections) |
| `sync_completed` | `trigger`: manual/launch; `changed` | launch and manual passes only, while active |
| `sync_failed` | `kind`; `trigger`: manual/launch/auto | manual/launch failures; an `auto` failure only at the first failure of an outage the person is around for (an overnight outage reports once they are back) |
| `message_action_performed` | `action`: read/unread/star/unstar/archive/unarchive/trash/restore; `scope`: message/conversation; `via`: toolbar/row/context_menu/menu/keyboard/reading_pane/bulk; `count` | an attempt (recorded before the request) |
| `action_failed` | `action`; `kind` | the request failed |
| `search_run` | `local_results`; `server_results` = rows the server tier ADDED (absent when it did not run) | ONE per Return; the auto (sparse-results) search reports nothing |
| `search_failed` | `kind` | a committed search's server tier failed |
| `compose_opened` | `kind`: new/reply/reply_all/forward/draft | a compose window can actually open (`prepareCompose`) |
| `draft_kept` | `via`: closed/save_button | a compose window was CLOSED leaving a server draft (replaces `draft_saved`); never from a window that merely disappeared |
| `message_sent` | `attachments`; `has_cc`; `has_bcc` | send ok |
| `send_failed` | `kind` (OutboxError kind) | send failed |
| `compose_discarded` | — | Delete in the composer |
| `draft_deleted` | — | a draft deleted from the Drafts list |
| `attachment_saved` | `count`; `all` | one save action (single, or Download All) |
| `remote_media_loaded` | — | the user allowed remote images |
| `label_changed` | `assigned`; `scope`: message/conversation | a label write that took |
| `account_added` | `outcome`: success/cancelled/failed; `kind` (failed only); `accounts` (success only; `1` = first sign-in) | Add Account |
| `account_reauthenticated` | `outcome`; `kind`; `automatic` | sign-in again |
| `account_removed` | — | sign-out |
| `account_switched` | `accounts` | the switcher (never a banner click) |
| `notification_opened` | `landed` | ONE per banner click (the switch and inbox reset it causes are not reported; a click that did not land reports the inbox view it left the person on) |
| `notifications_toggled` | `enabled` | Settings › Notifications |
| `notification_permission_resolved` | `granted` | macOS answered the prompt after turning notifications on |
| `setting_changed` | `setting`: list_density/account_tint/dock_badge/domain_tint/domain_default_from/domain_include_in_all/domain_count_in_badge/domain_notify/classification/classification_label/ai_gateway_token; `on` (switches only; `ai_gateway_token` = a token was saved) | a person changed a setting — never its value, domain or account |
| `update_check_requested` | — | the menu's Check for Updates only |
| `launch_failed` | `kind`: cache/restore/other | launch could not come up |

SDK auto-events: `app_open`, `session_start`, `session_end` (`duration_s`). `session_end` is only emitted when a later session starts in the same process, so sessions ended by quitting have no duration.

## Error kinds (explicit switch, payloads dropped)
- MailAPIError: unauthorized, insufficient_scope, not_found, cursor_expired, server, transport, decoding, other
- OAuthError (+ Add Account refusals): discovery, registration, server, state_mismatch, missing_code, reauth_required, missing_refresh_token, malformed_token, cancelled, web_auth, unknown_account, transport, invalid_origin, already_added, other
- OutboxError: invalid_recipient, no_recipients, attachment_too_large, draft_too_large, too_many_attachments, draft_conflict, file_unreadable, send_on_hold_recovering, send_on_hold_storage_not_ready, api_<MailAPIError kind>, api_other

## Never collected
Search text, mailbox/folder/label names, account origins, subjects, addresses, attachment names/sizes, IDs of any kind, bodies, error messages, exact counts, setting VALUES (colours, addresses, models), version strings beyond the SDK context.

## Opt-out copy (Settings › Privacy; README matches)
Sends which features you use (e.g. "archived a message", "opened search") to Herald's developer, along with the Herald version and build, macOS version, Mac model (e.g. "Mac15,3", never your Mac's name), processor type, and your language and region settings, tagged with a random per-install identifier so active installs can be counted. Never sent: your mail, subjects, addresses, search text, mailbox names, account details, file names, anything you type, your name, or your location. Turn this off and nothing further is sent, including anything queued.

## History
Original phases P1 t-e425c325 · P2 t-dcb470be · P3 t-a73fa929 · P4 t-1a8767ad · P5 t-197c4c10. 2026-10-06 pass: t-b14be37c (0.3.0), t-8788b917 (accurate numbers), t-f688c4be (record()), t-b62008f5 (event quality), t-0edf2b4a (new events). Removed: `mailbox_color_changed` (2026-09-28), `draft_saved` (→ `draft_kept`), the `selection` action scope, the `local/server` search scope.
