# Changelog

All notable changes to Herald are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

`scripts/release.sh <version>` refuses to run unless this file has a `## [<version>]` section,
and uses that section as the GitHub Release body and the Sparkle update notes. Write the notes
first, then cut the release.

## [Unreleased]

### Fixed
- Sign-in can no longer trap you. A sign-in that stops making progress — most often because macOS
  never opens the browser window it was asked for — now shows a **Cancel** button on both the
  first-run screen and the Add Account sheet, and Cancel abandons the sign-in itself rather than
  just closing the window over it. The screen is usable again immediately and a second attempt
  works — and a cancelled sign-in is really cancelled: the account it had already stored is
  removed and its token revoked, rather than quietly reappearing at the next launch. The re-auth
  banner offers the same Cancel while it is signing you back in. Herald #9.
- The spinner now says what it is waiting for: contacting your server, checking this Mac's
  registration, registering, waiting for the sign-in window, completing sign-in, saving
  credentials, setting up your mailbox. Each step is logged too, so a stuck sign-in names its
  location instead of just spinning.
- A browser sign-in that never reports back no longer waits forever: it is noted in the log after
  45 seconds and fails with an explanation after ten minutes. The deadline is deliberately long —
  macOS gives Herald no signal that the window actually opened, so a shorter one would close a
  consent page you were still typing into. Cancel is the fast way out.
- Sign-in and token requests have real deadlines (15s per request, 30s overall). They previously
  inherited the system default of seven days, so a server that accepted the connection and then
  went quiet could hang the sign-in indefinitely.
- Keychain reads and writes during sign-in and at launch no longer run on the main thread, so a
  stalled system keychain leaves Herald responsive — and cancellable — instead of frozen.
- Signing out now clears the cached server discovery for that address. Signing back into a server
  that was reinstalled in the meantime, without quitting Herald, could previously reuse the old
  install's endpoints.

## [0.4.0] - 2026-09-04

Herald now targets HQBase 1.3.4 or newer: forwarding and message rendering use API surfaces that
older servers don't have.

### Added
- Put Back. Trashed conversations can be restored ("Put Back") and archived ones moved back to
  the inbox — toolbar, context menu, ⌘⇧A, the `e` key and VoiceOver all follow one folder rule,
  so no more silent no-op archive from the Trash.
- Labels. Workspace labels sync into a sidebar section with per-label listings, colored name
  chips on rows and in the reading pane, and add/remove from the context menu, the reading-pane
  header, and the Message menu. Label colors match the web app.
- Signatures. Compose shows the signatures usable from the sending address, picks the address's
  default automatically, and lets you switch (or send with none). The server appends the
  signature, and a read-only preview shows exactly what will go out. A draft's saved signature is
  kept when you reopen it.
- Quoted-thread preview in compose. Reply and forward windows show a collapsed, read-only preview
  of the original the server will quote below your text.
- Instant sync. Herald now holds a lightweight wake connection to the server and refreshes the
  moment something changes, instead of waiting for the next poll. Polling remains as a fallback,
  stretched while the connection is healthy.
- Automatic sign-in repair. When a session expires while your HQBase web session is still alive,
  Herald re-runs the sign-in by itself the next time it's frontmost — the window flashes once and
  syncing resumes. The banner stays as a fallback and shows progress.

### Changed
- Forwarding uses the server's dedicated forward route, so the forwarded message can no longer be
  lost by sending before an autosave; the original's attachments ride along.
- Message rendering: text a sender wrote below the quoted history is now shown (it was silently
  dropped); quoted history collapses behind "Show quoted history"; nested quotes get per-level
  bars; plain-text mail renders in the system font with clickable links and tinted quote lines;
  wide tables scroll inside the message instead of the whole pane; dark mode no longer glares on
  unstyled light emails, and Increase Contrast is honored inside the message view.
- Attachments: downloads carry their real file type (previews and Quick Look work for files the
  server sends untyped or misnamed), inline-vs-attachment now follows the server's intent, the
  attachment bar survives offline reads, saving reuses the already-downloaded file, and a file
  being previewed or dragged can no longer be evicted mid-use. Failed inline images are called
  out instead of leaving silent holes.
- Sending marks messages read/unread, stars, archives and trashes more reliably from the Trash
  and Archive scopes, which the server treats specially.
- The Privacy pane's usage-statistics toggle now says when analytics aren't included in a build
  (dev copies) instead of rendering a switch that snaps back, and confirms opt-out in real builds.
- Accessibility: selection state in the signature menu, contrast-safe label chips, VoiceOver
  announcements for session-repair and blocked/failed image banners, and a Labels submenu in the
  Message menu.

### Fixed
- Sessions no longer log out when two Herald copies share one account (server-side fix Herald
  asked for in HQBase 1.3.x, plus client-side hardening).
- A rejected sync cursor now recovers by re-syncing instead of failing forever.
- Cached data written by an older Herald can no longer crash the app on read; the cache degrades
  and heals on the next sync.

## [0.3.0] - 2026-08-19

### Added
- Multiple accounts. Add more than one HQBase account; every signed-in account keeps syncing in
  the background, so unread counts stay live while you read another. An account switcher sits at
  the top of the sidebar. Sign-out and re-authentication apply to one account at a time, and a
  composer keeps sending through the account it was opened from.
- Drafts folder. Drafts are cached locally and shown as a sidebar item with a count; double-click
  or Return reopens one in the composer with no round trip, Delete removes it. A draft with a
  composer open is protected from being overwritten or removed by a poll.
- Search, in two tiers. Typing filters instantly across subject, sender, recipients and the cached
  body text of each row; Return (or a thin local result) also asks the server for the current
  mailbox and folder, with a status line showing progress, count, or an offline notice. Matches
  are highlighted in subject and snippet; ⌘F focuses the search field. Server-only results can be
  opened and acted on (archive, trash, star, read) like any other row.
- New-mail notifications. Optional local banners for inbound, unread inbox mail (never on first
  sign-in or a first mailbox listing), grouped when many arrive at once; clicking one switches to
  the right account and opens the conversation. A Dock badge shows the unread total across all
  accounts. Both switches live in Settings → Notifications.
- Attachments in compose: drag-and-drop anywhere on the window, or ⌘V a file or copied image;
  uploads show as chips with a spinner and cancel; Send waits for queued uploads. Limits now match
  the server exactly (25 MiB per file, 25 MiB per draft, 20 files). In the reading pane, Quick Look
  previews an attachment and you can drag it out to Finder.
- Anonymous, opt-out usage analytics (Settings → Privacy) — see README for exactly what is and
  isn't sent. Herald never sends mail content, subjects, addresses, search text, mailbox names,
  account details, file names, or anything you type.

### Fixed
- Clearing the search field takes effect immediately instead of after the typing delay.
- A body just opened in the reading pane is searchable at once, even during a sync burst.
- Clicking a new-mail banner while the Drafts folder is open now actually leaves Drafts.

### Changed
- Analytics client updated to swift-stats 0.2.0: usage batches are held (not sent) while Low Data
  Mode is on, requests time out instead of hanging, and the local queue survives a full disk by
  falling back to memory. No change to what is collected.

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
