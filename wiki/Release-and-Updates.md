---
created: 2026-08-19
updated: 2026-08-19
---

# Release and Updates

Herald uses Sparkle for automatic updates. Releases are cut by hand using scripts that sign, notarize, and publish.

## Sparkle setup

Herald ships with Sparkle 2 (via SPM). The updater:

- Checks for updates once a day (can also be triggered manually via "Check for Updates…")
- Never installs silently — shows release notes and waits for user approval
- Installs via Sparkle's bundled Installer XPC service (`SUEnableInstallerLauncherService`); the download happens in-process — the Downloader XPC service is deliberately not enabled

The feed is at `https://awizemann.github.io/herald/appcast.xml`, published to the `gh-pages` branch.

## Signing and notarization

Every build must be:

1. **Signed with Developer ID Application** — the owner's certificate in the login Keychain
2. **Notarized by Apple** — Submitted via `xcrun notarytool` and verified (stapled to the binary)
3. **Signed with Sparkle Ed25519 key** — The appcast XML is signed; the public key is baked into the app

The Sparkle private key lives ONLY in the owner's Keychain (account `Herald`). It is not in the repo, CI, or anywhere else. If lost, it cannot be recovered; a new key must be minted and the app rebuilt.

## Release scripts

Two scripts automate the process:

**`./scripts/sparkle-keys.sh`** (run once, ever) — Mint the Sparkle Ed25519 keypair and print the public key for `project.yml`.

**`./scripts/release.sh <VERSION> [--dry-run]`** — Cut a release:

```sh
APP_STATS_WRITE_KEY="$(cat <keyfile-outside-the-repo>)" ./scripts/release.sh 0.3.0 --dry-run   # everything except notarize, publish, tag
APP_STATS_WRITE_KEY="$(cat <keyfile-outside-the-repo>)" ./scripts/release.sh 0.3.0             # cut the release
```

The script redacts the key from xcodebuild's output, and after export asserts both the baked key and the bundled `PrivacyInfo.xcprivacy`.

The script:

1. Bumps `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`
2. Regenerates the Xcode project
3. Archives and exports a Release build
4. Signs with Developer ID
5. Notarizes and staples
6. Packages `Herald-<version>.zip` with `ditto -c -k --keepParent --norsrc` and re-verifies the extracted app
7. Runs `generate_appcast`, signing with the Sparkle key from the Keychain
8. Commits the version bump, pushes `main` and tag `v<version>`
9. Creates the GitHub release with the CHANGELOG section as its body
10. Pushes `appcast.xml` to `gh-pages`

Pre-conditions:

- Working tree is clean (no uncommitted changes)
- On the `main` branch
- Developer ID certificate is in the Keychain
- A notarytool keychain profile exists (`herald-notary` by default; override with `NOTARY_PROFILE=<name>`)
- `APP_STATS_WRITE_KEY` is set in the environment — the swift-stats write key baked into the release `Info.plist` (supply it from your secret store for that one command; it must never be committed). Dev builds leave it empty and analytics are a no-op.
- GitHub CLI (`gh`) is authenticated
- Sparkle private key in Keychain matches the committed public key

## One-time setup

Install the Developer ID certificate:

```sh
# Import a .p12 exported from Apple Developer
security import my-cert.p12 -k ~/Library/Keychains/login.keychain
```

Store the notarytool credentials:

```sh
xcrun notarytool store-credentials "herald-notary" \
  --key AuthKey_XXX.p8 \
  --key-id <KEY_ID> \
  --issuer <ISSUER_ID>
```

Mint the Sparkle keypair (once):

```sh
./scripts/sparkle-keys.sh
```

Copy the printed `SUPublicEDKey` into `project.yml`, commit, and regenerate the project.

## Release notes

Sparkle reads release notes from `CHANGELOG.md` (Keep a Changelog format). Before releasing, move `[Unreleased]` items to a `## [X.Y.Z] - YYYY-MM-DD` section. `release.sh` refuses to proceed without that section.

Notes are shown in "Check for Updates…" and in the GitHub Release body.

## After the release

- `curl -s https://awizemann.github.io/herald/appcast.xml | grep <version>` (Pages can lag a minute behind the raw branch)
- `spctl -a -vv` on the downloaded zip's app: expect `accepted, source=Notarized Developer ID`
- Launch the previous version and confirm Sparkle offers the new one

`generate_appcast` only scans the current release folder, so the published appcast always advertises the single latest version — exactly what Sparkle needs.

---
_Last updated: 2026-08-19 — release and updates runbook; fact-checked against the code for v0.3.0_