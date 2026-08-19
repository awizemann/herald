# Changelog

All notable changes to Herald are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

`scripts/release.sh <version>` refuses to run unless this file has a `## [<version>]` section,
and uses that section as the GitHub Release body and the Sparkle update notes. Write the notes
first, then cut the release.

## [Unreleased]

### Added
- Anonymous, opt-out usage analytics (Settings → Privacy) — see README for what is and isn't sent.

## [0.2.1] - 2026-08-18

### Fixed
- Some newly arrived messages could still show as a clipped, one-line row until the list was
  scrolled or re-measured — a stubborn case the earlier row-height fix missed. Freshly inserted
  rows now reserve their full height immediately, so new mail always lands at the right size.

### Changed
- A development build now runs side by side with the released app without the two signing each
  other out: debug builds use their own Keychain namespace and local cache. Only relevant if you
  run a build from source alongside a released copy.
- Internal quality work with no change to how Herald behaves: spacing, corner radii, and the two
  display glyphs are now design tokens instead of scattered literals; the two largest source
  files were split under the project's size limit; the account store's index lock moved from
  NSLock to os_unfair_lock; and a handful of ignorable error paths are now documented or logged.

## [0.2.0] - 2026-08-18

### Added
- Delta sync. On HQBase servers that publish the new changes feed (`GET /api/v1/changes`, shipped
  upstream on 2026-08-18), Herald takes a checkpoint, lists each mailbox once using the new
  paginated `GET /api/v1/messages`, and from then on applies only what changed — including
  deletions and moves made by other clients — instead of re-listing every folder every 15
  seconds. The sync cursor is saved after every applied page, so an interrupted sync resumes
  where it stopped. Older servers keep the previous behaviour automatically.
- Mailbox access changes are honoured each sync: mail from a mailbox you can no longer read is
  removed from the local cache; a newly readable mailbox is fully listed before its changes are
  applied.

### Fixed
- Triage actions can no longer be undone by a stale update arriving from the server while the
  action is still being sent; the server's confirmed state is applied once it answers.
- On servers with pagination, folders with more than 100 messages are now listed completely.

### Fixed (continued)
- Signing in no longer expires after a few hours when two copies of Herald share one account
  (for example a released build and a development build): Herald now treats the Keychain as the
  source of truth — it re-checks stored tokens before refreshing or retrying, adopts tokens another
  process already rotated, and only signs you out when the server has genuinely rejected the
  refresh token. Refresh timing is jittered so shared tokens don't collide. (Herald #1 follow-up;
  upstream HQBase/hqbase#41 asks for a server-side reuse window.)
- Deleting a message no longer opens the thread below it; the selection just moves on. (#5)
- A just-deleted (or archived) message appears in Trash/Archived immediately, and the toolbar
  Refresh reloads the view you're looking at. (#6)
- In Trash, "Move to Archive" now works per message (the only way out of Trash the API offers)
  and Herald no longer sends the conversation-level archive/trash actions the server ignores
  there; if the server reports an action affected nothing, the optimistic change is reverted at
  once. A proper "Put back" needs a server action — upstream HQBase/hqbase#42. (#7, #8)

## [0.1.3] - 2026-08-17

### Fixed
- Sign-ins no longer expire after about an hour. HQBase's protected-resource metadata lists only
  the API permissions (`mail:read`, `mail:write`, `mail:send`) and Herald requested exactly that
  set, so it never asked for `offline_access` and never received a refresh token; when the first
  access token expired, the only recovery was signing in again. Herald now always requests
  `offline_access` in addition to the advertised scopes. Existing accounts need one more sign-in
  to obtain a refresh token — after that, sessions persist. (#1)
- New mail could appear as a clipped, one-line row until the list re-measured it; rows now have a
  stable minimum height.

## [0.1.2] - 2026-08-16

### Fixed
- Release packages no longer contain AppleDouble (`._*`) entries; extracting with Finder or `unzip`
  now passes `codesign --verify --strict --deep`. The release script strips extended attributes,
  archives with `--norsrc`, and verifies the zip with `unzip`. (#2)
- When the server refuses a token refresh — or no refresh token was granted at sign-in — Herald
  now shows the "Sign in again" banner (whose button re-runs consent for the same account)
  instead of a "Sync problem" with a Retry that could never succeed. (#1)
- Error descriptions are never logged as public data; log lines carry a payload-free error code
  and keep the description private, so server messages that echo recipients or subjects stay
  out of the unified log. A source-level test guards this. (#3)
- Clicking a conversation's text reliably selects it. A tap gesture added for click-to-open was
  racing the list's own selection; selection now opens multi-message threads by itself. (#4)

## [0.1.1] - 2026-08-16

### Added
- Per-mailbox colors: each mailbox gets a stable default tint, and Settings → Mailboxes (⌘,)
  lets you pick your own. Chips in the message list carry the mailbox name in that color.
- Human-readable dates in the message list ("6:44 PM", "Yesterday", "Tue", "Aug 15"), with the
  full date and time as a tooltip and for VoiceOver.
- Message previews are cleaned: quoted history, "On … wrote:" attributions and forwarded-message
  dividers are stripped and HTML entities decoded.

### Changed
- Message rows are laid out as mailbox chip → sender → subject → preview, with the date
  right-aligned above an aligned tool column (message count, thread chevron, star) that has the
  same width on every row.
- Selecting a conversation with more than one message now opens its message list directly;
  ⎋, ⌘[ or the back button return to the conversation list.
- Thread view lists newest message first and selects it automatically, matching the
  conversation list.
- Settings window is wider; each mailbox is on one line.

## [0.1.0] - 2026-08-16

First public release. A native macOS client for HQBase, talking only to the public Mail API v1
with OAuth 2.1 PKCE bearer tokens.

### Added
- Sign in to any HQBase 1.1+ instance with OAuth (PKCE, dynamic client registration); tokens
  live in the Keychain and refresh silently; sign-out revokes the refresh token server-side.
- All mailboxes with a mailbox picker; Inbox, Starred, Sent, Archived and Trash.
- Threaded reading with sanitized HTML: remote images are blocked until you choose to load
  them, which also trusts the sender for the web app; links open in your browser.
- Read/unread, star, archive and trash with keyboard shortcuts and menu commands; VoiceOver and
  Full Keyboard Access support throughout.
- Reply, reply all, forward and new message with autosaved drafts and attachments.
- Local cache for instant launch, background polling sync (15 s while active).
- Sparkle auto-updates; Developer ID signed and notarized; sandboxed.

[Unreleased]: https://github.com/awizemann/herald/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/awizemann/herald/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/awizemann/herald/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/awizemann/herald/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/awizemann/herald/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/awizemann/herald/releases/tag/v0.1.0
