---
title: Herald Build and Toolchain
type: note
permalink: hqbase-mac/operations/herald-build-and-toolchain
tags: [build, xcode]
created: 2026-08-16
updated: 2026-08-18
---

## Observations
- [fact] Toolchain at kickoff (2026-08-15): Xcode 27.0 beta (27A5237l), Swift 6.4, xcodegen 2.45+; macOS deployment target 15.0 (lowered 2026-08-15; nothing 26-only used); project.yml is the source of truth and Herald.xcodeproj is a generated, gitignored artifact — run `xcodegen generate` #toolchain
- [rule] Always pass -project Herald.xcodeproj -scheme Herald -destination 'platform=macOS' and, from the CLI while Xcode has the project open, a throwaway -derivedDataPath (why: two build systems on one DerivedData corrupts build.db — "disk I/O error"/.air.tmp rename failures that look like disk problems) #xcodebuild
- [fact] `scripts/build-detached.sh` (no args) regenerates the project if needed, builds into ./DerivedData, and launches a dev copy quitting only its own previous instance #dogfood
- [rule] Never push to the remote without explicit approval; commit freely on main, branch for larger work #git

## Relations
- relates_to [[Herald Architecture]]

## Update (2026-08-15 — plugin validation)
- [gotcha] xcodebuild fails at "Validate plug-in OpenAPIGenerator" unless `-skipPackagePluginValidation` is passed (the Xcode GUI prompts once to trust it); build-detached.sh passes it. #plugin
- [gotcha] xcodegen unit-test bundles need `GENERATE_INFOPLIST_FILE: YES` explicitly or code signing fails "does not have an Info.plist". #xcodegen
- [rule] NEVER run the dev copy (build-detached.sh) while /Applications/Herald.app is signed in — same bundle id, same keychain, one rotating refresh token → the two processes log each other out (see API contract note "ROOT CAUSE #3"); build-detached.sh now refuses unless HERALD_ALLOW_BOTH=1. Debug with `log show … --predicate 'subsystem == "com.wizemann.herald" AND process == "Herald"'` (xctest shares the subsystem) #two-processes


## Update (2026-08-18 — dev copy isolation)
- [decision] Debug builds use Keychain service `com.wizemann.herald.debug` and cache folder `Application Support/Herald-Debug` (`#if DEBUG` in KeychainStore / MailStoreContainer). Why: a login-keychain item is ACL-locked to the creating code signature; the dev copy (Apple Development cert) and release app (Developer ID) differed, so sharing one item prompted for the login keychain password on every dev launch and two processes rotated one refresh token. build-detached.sh no longer refuses to run beside the release app; sign in once in the dev copy #keychain #dev
