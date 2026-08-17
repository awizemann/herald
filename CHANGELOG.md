# Changelog

All notable changes to Herald are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

`scripts/release.sh <version>` refuses to run unless this file has a `## [<version>]` section,
and uses that section as the GitHub Release body and the Sparkle update notes. Write the notes
first, then cut the release.

## [Unreleased]

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

[Unreleased]: https://github.com/awizemann/herald/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/awizemann/herald/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/awizemann/herald/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/awizemann/herald/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/awizemann/herald/releases/tag/v0.1.0
