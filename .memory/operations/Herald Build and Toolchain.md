---
title: Herald Build and Toolchain
type: note
permalink: hqbase-mac/operations/herald-build-and-toolchain
tags: [build, xcode]
source_paths: [scripts/build-detached.sh, project.yml]
source_paths_inferred: false
source_sha: f6c2d650ab02b6ee02cbfdf8276a48292bd5b22b
created: 2026-08-16
updated: 2026-09-27
reviewed: 2026-09-28
reviewed_by: audit:claude-code (background)
---

## Observations
- [fact] Toolchain at kickoff (2026-08-15): Xcode 27.0 beta (27A5237l), Swift 6.0, xcodegen 2.45+; macOS deployment target 15.0 (lowered 2026-08-15; nothing 26-only used); project.yml is the source of truth and Herald.xcodeproj is a generated, gitignored artifact — run `xcodegen generate` #toolchain
- [rule] Always pass -project Herald.xcodeproj -scheme Herald -destination 'platform=macOS' and, from the CLI while Xcode has the project open, a throwaway -derivedDataPath (why: two build systems on one DerivedData corrupts build.db — "disk I/O error"/.air.tmp rename failures that look like disk problems) #xcodebuild
- [fact] `scripts/build-detached.sh` (no args) regenerates the project if needed, builds into ./DerivedData, and launches a dev copy quitting only its own previous instance #dogfood
- [rule] Never push to the remote without explicit approval; commit freely on main, branch for larger work #git
- [fact] Font bundling system (added 2026-09-27): Herald excludes the `Fonts/` subfolder from regular sources, then includes `Herald/Fonts` as a folder resource (buildPhase: resources). At launch, Info.plist's `ATSApplicationFontsPath: Fonts` registers every font in `Contents/Resources/Fonts` declaratively — fonts are available before any view requests them, no CTFontManager call needed. Registered fonts are process-scoped (no sandbox entitlement required). See MailTheme.Typography #fonts

## Relations
- relates_to [[Herald Architecture]]
- relates_to [[Herald UI Testing]]

## Update (2026-08-15 — plugin validation)
- [gotcha] xcodebuild fails at "Validate plug-in OpenAPIGenerator" unless `-skipPackagePluginValidation` is passed (the Xcode GUI prompts once to trust it); build-detached.sh passes it. #plugin
- [gotcha] xcodegen unit-test bundles need `GENERATE_INFOPLIST_FILE: YES` explicitly or code signing fails "does not have an Info.plist". #xcodegen
- [fact] RETIRED 2026-09-27 (was: "never run the dev copy while /Applications/Herald.app is signed in"): the shared-refresh-token cause was fixed by the separate Debug Keychain namespace (2026-08-18) and every remaining shared resource (bundle id, container, prefs, callback scheme, notification routing) by the separate Debug bundle id (U6a, below). The dev copy and the release app may run side by side. Debug with `log show … --predicate 'subsystem == "com.wizemann.herald" AND process == "Herald"'` (xctest shares the subsystem) #two-processes


## Update (2026-08-18 — dev copy isolation)
- [decision] Debug builds use Keychain service `com.wizemann.herald.debug` (renamed `.dev` on 2026-09-27 — see U6a update) and cache folder `Application Support/Herald-Debug` (`#if DEBUG` in KeychainStore / MailStoreContainer). Why: a login-keychain item is ACL-locked to the creating code signature; the dev copy (Apple Development cert) and release app (Developer ID) differed, so sharing one item prompted for the login keychain password on every dev launch and two processes rotated one refresh token. build-detached.sh no longer refuses to run beside the release app; sign in once in the dev copy #keychain #dev

- [gotcha] 2026-09-04: running `swift build`/`swift test` on HeraldKit alone rewrites `HeraldKit/Package.resolved` and DROPS the app-only Sparkle pin — `git checkout HeraldKit/Package.resolved` before committing after package-level builds; the app build via xcodebuild restores/needs the pin #package-resolved



## Update (2026-09-19 — sign-in "browser opens then dies")
- [gotcha] Sign-in that reaches stage `waitingForBrowser` and then logs "web authentication has reported nothing yet; still waiting" with no callback is a BROWSER-SIDE hang, not Herald: ASWebAuthenticationSession runs in Safari's engine, and a wedged Safari swallows the callback. Restarting Safari fixed it live (2026-09-19, dev copy against production 1.4.0). A further hazard worth clearing first: `lsregister -dump` accumulates one binding per DerivedData build, so a stale bundle can receive the callback (release and dev no longer share a scheme since U6a) #sign-in-hang
- [fact] Reading Herald's log from a Claude shell: put the `log show … --predicate '…'` line in a script file and run it with bash — the inline form fails with "too many arguments" under the session's zsh quoting and looks like an empty log #log-show



## Update (2026-09-26 — test runs)
- [gotcha] Adding a NEW test/source file needs `xcodegen generate` before xcodebuild (the generated project lists files; it is not a folder reference), and the CLI test command needs `-skipPackagePluginValidation` too. Once, after all 299 app tests had passed, xcodebuild reported "xctest encountered an error (The test runner hung before establishing connection)" and TEST FAILED — an immediate rerun was green; treat that message as runner flake, not a test failure #xcodebuild-test



## Update (2026-09-27 — Debug is a separate app, U6a, commits dff1fed + 2000b47)
- [decision] Debug builds have their OWN bundle id `com.wizemann.herald.debug` (project.yml `targets.Herald.settings.configs.Debug.PRODUCT_BUNDLE_IDENTIFIER`); Release stays `com.wizemann.herald` byte-for-byte (verified: `plutil -p` of a Release build shows id + single URL scheme `com.wizemann.herald`). Why (Alan's decision): a dev copy / UI-test run must never terminate the release app (`XCUIApplication.launch()` kills same-id instances) or share its prefs, window geometry, sandbox container, attachment scratchpad, notification clicks or OAuth callback scheme #dev #bundle-id
- [fact] What follows the id: `CFBundleURLTypes` = `$(PRODUCT_BUNDLE_IDENTIFIER)`; `DynamicClientRegistration.callbackScheme`/`redirectURI` are `#if DEBUG` `com.wizemann.herald.debug[:/oauth/callback]` (DebugIdentityTests pins scheme == Info.plist == bundle id); Sparkle mach-lookup names resolve to `…debug-spks/-spki` but Sparkle NEVER starts in Debug (`UpdateService.isDebugBuild`; the dev copy's Check for Updates is disabled). Container-scoped things (temp scratchpad, UserDefaults, WKContentRuleList store, notification permission) are separate automatically #dev #bundle-id
- [decision] Debug Keychain service is now `com.wizemann.herald.dev` (was `.debug`). The old `.debug` items were written by the previous dev copy (release bundle id → different designated requirement → reads would prompt) and hold a `client_id` registered with the RELEASE redirect URI, which the new scheme cannot use. Consequence: the dev copy signs in again once and registers its own OAuth client; the orphaned `.debug` items can be deleted in Keychain Access. Cache folder `Herald-Debug` kept (redundant with the new container, harmless) #keychain #dev
- [decision] Logger subsystem stays `com.wizemann.herald` in BOTH configs (one `log show --predicate 'subsystem == "com.wizemann.herald"'` covers dev, release and tests; filter by `process`/`processImagePath` to tell them apart). `UsageAnalytics.appId` stays the release id (Debug never reports) #logging
- [fact] DerivedData layout: build-detached.sh uses `./DerivedData`; `scripts/ui-tests.sh` builds into its own `DerivedData-UITests/` (gitignored), so build-detached.sh's `pkill -f $PWD/DerivedData/Build/…/Herald` never kills a UI-test run and they never share build.db. A UI run QUITS a running dev copy (same debug id). build-detached.sh's pkill can still hit a unit-test host (same DerivedData) — don't run both at once. UI-test guards, harness and running rules: [[Herald UI Testing]] #dogfood
- [fact] Release builds are gated by `scripts/verify-release-identity.sh` (called from release.sh): exact release id + single callback scheme, no Debug/UI-test strings — details in [[Herald UI Testing]] #release
