---
title: Herald Release Pipeline
type: note
permalink: hqbase-mac/operations/herald-release-pipeline
tags:
- release
- sparkle
- operations
---

Direct-download distribution with Sparkle 2 auto-updates (decision 2026-08-15: HQBase users are
self-hosters who won't build from Xcode; App Store deferred until the trademark/adoption question
is settled). Public repo: https://github.com/awizemann/herald (AGPL-3.0, CI on macos-15/Xcode 26.6).

## Observations
- [fact] Sparkle 2.9.2 via SPM; feed `https://awizemann.github.io/herald/appcast.xml` (gh-pages branch of the same repo, pushed by release.sh through a throwaway worktree); enclosures on GitHub Releases; sandbox needs the two mach-lookup exceptions `$(PRODUCT_BUNDLE_IDENTIFIER)-spks/-spki` + `SUEnableInstallerLauncherService` (Downloader XPC NOT enabled — in-process download) #sparkle
- [rule] `UpdateService.isAvailable` is decided from the Info dictionary BEFORE any Sparkle object exists (key present, non-placeholder, 32 base64 bytes); otherwise the updater is never constructed and the menu item is disabled — this is what keeps CI/unsigned/test-host builds from Sparkle's abort-on-start. Under tests the updater is never started even with a real key #guard
- [rule] `./scripts/release.sh <version> [--dry-run]`: preflights clean tree on main, Developer ID identity, notarytool profile `herald-notary`, Sparkle keypair (Keychain account "Herald") matching `SUPublicEDKey` in project.yml (project.yml is the source of truth — Info.plist is generated); then archive → export (automatic signing, no provisioning profile needed — no profile-bound capabilities) → notarize+staple → ditto zip → generate_appcast (binary resolved from THIS repo's DerivedData first; a bare find picked another project's Sparkle) → gh release → appcast on gh-pages #release
- [todo] Owner one-time setup: `./scripts/sparkle-keys.sh` then paste the SUPublicEDKey line into project.yml + back the private key up ONCE to a password manager; `xcrun notarytool store-credentials herald-notary --key <AuthKey>.p8 --key-id <ID> --issuer <ISSUER>`; enable GitHub Pages on `gh-pages` in repo settings after the first release creates it #setup
- [fact] Private EdDSA key lives ONLY in the owner's Keychain (never in repo/chat/memory); public key only in project.yml #keys

## Relations
- relates_to [[Herald Build and Toolchain]]
- relates_to [[Herald Project Overview]]

## Update (2026-08-16 — first release run findings)
- [gotcha] `xcodebuild -exportArchive` with signingStyle AUTOMATIC fails "No Accounts" under a CLI Xcode with no signed-in developer account even when another Xcode has one → ExportOptions uses `signingStyle: manual` + `signingCertificate: Developer ID Application` (Scarf pattern); no -allowProvisioningUpdates #export
- [gotcha] Any profile-bound entitlement (keychain-access-groups was ours) makes export demand a provisioning profile ("requires a provisioning profile") — Herald ships none, so entitlements must stay to sandbox + network.client + user-selected files + Sparkle mach-lookup exceptions #entitlements
- [fact] Notarization reuses the team-level profile `shabubox-notary` (`NOTARY_PROFILE=shabubox-notary ./scripts/release.sh <v>`); credentials are per team, not per app #notary

## Update (2026-08-16 — release notes are part of the runbook)
- [rule] RUNBOOK step 0: write the version's notes in CHANGELOG.md (`## [x.y.z] - date`, Keep-a-Changelog; move `[Unreleased]` items down). release.sh PREFLIGHT FAILS without that section; `scripts/changelog-section.py <v> [--html]` extracts it → GitHub Release body AND `Herald-<v>.html` beside the zip so generate_appcast embeds it as the Sparkle update notes. releases/**/RELEASE_NOTES.md and *.html are derived and gitignored #release-notes
- [done] Sparkle self-update PROVEN 2026-08-16: installed 0.1.0 offered and installed 0.1.1 — the pipeline is verified end to end #verified
- [rule] Full release runbook: (1) CHANGELOG section, (2) tree clean on main, (3) `NOTARY_PROFILE=shabubox-notary ./scripts/release.sh <v>` [--dry-run first if anything changed in the pipeline], (4) verify `curl -s https://awizemann.github.io/herald/appcast.xml | grep <v>` and `spctl -a -vv` on the downloaded zip, (5) push main (release.sh commits the version bump) #runbook
