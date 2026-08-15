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

- macOS 15 (Sequoia) or later, Apple silicon
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

## Updates

Herald updates itself with [Sparkle 2](https://sparkle-project.org). The app checks its appcast
once a day and **never installs silently** — it tells you an update is ready and waits
(`SUAutomaticallyUpdate: false`). You can also check on demand: **Herald → Check for Updates…**

- Feed: `https://awizemann.github.io/herald/appcast.xml` (the `gh-pages` branch of this repo).
  Only that small XML file is served from Pages; the app itself is a GitHub release asset.
- Every update is signed with an EdDSA (ed25519) key and verified against the `SUPublicEDKey`
  baked into the app, on top of Apple notarization and Gatekeeper.
- **The private signing key exists only in the owner's login Keychain** (account `Herald`). It is
  not in this repo, not in CI, and not recoverable if lost. Only the public half — which merely
  verifies — is committed, in `project.yml`.
- On a fresh clone `SUPublicEDKey` is still `<PLACEHOLDER-SEE-README>`. In that state
  `UpdateService` deliberately never constructs Sparkle's updater (which would abort on start),
  logs a warning, and leaves "Check for Updates…" disabled — which is also what lets unsigned CI
  and test builds run. Mint the real key with `./scripts/sparkle-keys.sh`.
- Under the App Sandbox the update is installed by Sparkle's bundled Installer XPC service
  (`SUEnableInstallerLauncherService` plus the two `-spks`/`-spki` mach-lookup exceptions in
  `Herald/Herald.entitlements`). The Downloader XPC service is not enabled — Herald already has
  outgoing network access, so Sparkle downloads in-process.

## Releasing

Two scripts, both run locally by the owner; nothing about signing lives in CI.

```sh
./scripts/sparkle-keys.sh              # once, ever: mint the Sparkle keypair, print SUPublicEDKey
./scripts/release.sh 0.1.0 --dry-run   # everything except notarize, publish, and tag
./scripts/release.sh 0.1.0             # cut the release
```

`release.sh` bumps `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`, regenerates
the project, archives Release, exports and signs with Developer ID, notarizes and staples,
packages with `ditto -c -k --keepParent`, signs the appcast with the Keychain key, creates the
GitHub release, and pushes `appcast.xml` to `gh-pages` (creating that orphan branch on the first
run). It refuses to start unless the signing certificate, the notarytool profile, `gh` auth, and
a Sparkle private key matching the committed public key are all present, and it will not release
from a dirty tree or a non-`main` branch.

One-time setup beyond the keypair: a **Developer ID Application** certificate for team
`3Q6X2L86C4` in the login Keychain, and a notarytool profile —

```sh
xcrun notarytool store-credentials "herald-notary" \
  --key <AuthKey_XXXX>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
```

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
