# Herald

A native macOS email client for [HQBase](https://hqbase.io) — the AGPL shared-mailbox workspace
that runs in your own Cloudflare account.

Herald talks only to HQBase's public **Mail API v1** (`/api/v1`) with OAuth 2.1 PKCE bearer tokens.
Nothing else: no cookies, no scraping, no third-party services. Your mail stays between your Mac
and your HQBase instance.

> Herald is compatible with HQBase. It is an independent project and is **not affiliated with or
> endorsed by the HQBase project.** "HQBase" is a trademark of its respective owner.

## Status

Early, working, dogfooded against a real HQBase ≥ 1.1.0 instance:

- Sign in with OAuth (PKCE, dynamic client registration, tokens in the Keychain)
- All your mailboxes, Inbox / Starred / Sent / Archived / Trash
- Threaded reading with sanitized HTML (remote images blocked until you trust the sender)
- Read / unread, star, archive, trash — with keyboard shortcuts
- Reply, reply all, forward, new message
- Local cache for instant launch; polling sync

Not yet: attachments in compose, drafts folder, search, multiple accounts UI, notifications.

## Requirements

- macOS 26 or later, Apple silicon
- An HQBase instance running **1.1.0 or later** (public Mail API + OAuth bearer support)
- Xcode 27 to build

## Build

```sh
brew install xcodegen
xcodegen generate
open Herald.xcodeproj
```

Or from the command line, into isolated DerivedData, and launch a dev copy:

```sh
./scripts/build-detached.sh
```

`project.yml` is the source of truth; `Herald.xcodeproj` is a generated artifact.

## Architecture (short version)

- `HeraldKit/` — SPM package with all logic. `HeraldAPI` is a leaf target holding only the
  swift-openapi-generator output for the vendored HQBase Mail API v1 spec. `HeraldKit` wraps it
  behind `MailAPIClient` and owns auth (`Auth/`), the SwiftData cache + sync engine (`Sync/`),
  and compose (`Compose/`). Views only ever see Sendable value DTOs.
- `Herald/` — the SwiftUI app: one `@Observable` view-model, three-pane split view, a locked-down
  `WKWebView` for message bodies, menu-bar Commands.
- Swift 6 strict concurrency with default `@MainActor` isolation; Swift Testing throughout.

The design record — architecture, conventions, decisions, and every server-contract gotcha
found along the way — lives in `.memory/` (managed by [Memophant](https://memophant.co)).

## Contributing to HQBase

Herald exists because HQBase's author shipped a versioned public API and OAuth bearer support in
response to [HQBase/hqbase#11](https://github.com/HQBase/hqbase/issues/11). Server-side changes
Herald needs go upstream as small, separate PRs; this repo is the client only.

## License

AGPL-3.0-only, matching HQBase. See `LICENSE`.
