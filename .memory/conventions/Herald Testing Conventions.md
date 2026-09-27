---
title: Herald Testing Conventions
type: note
permalink: hqbase-mac/conventions/herald-testing-conventions
tags: [testing]
source_paths: [HeraldKit/Tests/HeraldKitTests/Support/FakeServer.swift, HeraldTests/Support/ScratchDefaults.swift, HeraldKit/Tests/HeraldKitTests/Sync/FakeMailAPIClient.swift, HeraldKit/Tests/HeraldKitTests/Compose/OutboxServiceTests.swift, HeraldKit/Tests/HeraldKitTests/Auth/SessionRejectionLatchTests.swift, project.yml]
source_paths_inferred: false
source_sha: ed2278edf6151b3ae922b22fdc4854a1ec668ab5
created: 2026-08-16
updated: 2026-09-27
reviewed: 2026-09-27
reviewed_by: claude-opus-5-5
---
General unit-testing conventions for Herald (HeraldTests app-hosted suites + HeraldKit package tests). UI (XCUITest) testing lives in [[Herald UI Testing]].

## Observations
- [convention] Swift Testing only (@Suite/@Test/#expect); protocol-oriented fakes injected via `nonisolated protocol`s (fake actors need it) #framework
- [convention] Tests must DISCRIMINATE: each test states (in name or comment) what broken behavior it would fail on — a test that only re-asserts what the code obviously does is a checkbox and gets removed in audit #discriminating
- [convention] Network is faked at URLProtocol level (`FakeServerProtocol`, HeraldKit/Tests/HeraldKitTests/Support/FakeServer.swift) with canned responses keyed by path, so the generated client + auth + sync run end-to-end without a server; no timing-dependent tests — poll with early exit or await events, never sleep-then-assert #network
- [convention] App-hosted suites run Debug (ENABLE_TESTABILITY, host bundle id `com.wizemann.herald.debug`); HeraldKit tests run via `swift test` in HeraldKit/ AND through the `Herald` scheme (`-scheme Herald test` runs HeraldTests + HeraldKitTests, never the UI suite) #targets
- [constraint] `grep -rn "static let .*= Notification.Name" --include='*.swift' Herald HeraldKit/Sources | grep -v nonisolated` and `grep -rn "print(" --include='*.swift' Herald HeraldKit/Sources` must both be empty #guards

## Discrimination and mutation checks
- Verify a test discriminates by mutating the code under test and running `swift test --filter <Suite>` (or `-only-testing:` for app suites). macOS has no `timeout`/`gtimeout`, so watch for hangs by hand.
- Record in the test's comment which mutation it was checked against when the regression is non-obvious.

## Fakes
- `FakeServer.route(_:_:_:)` is variadic; `route(_:_:responses:)` is the array form — use it from helpers that forward a variadic list (Swift cannot splat).
- A fake's gate must keep EVERY parked continuation (keeping only the last leaks the earlier ones — `FakeMailAPIClient` was fixed for this in 176efc5).
- Prefer event seams over counters polled against a deadline: `FakeMailAPIClient.observeGateArrivals` (a call parked on the armed gate) and `OutboxService.observeJoinedCreates` (internal test seam: a save joined an in-flight create) feed one `AsyncStream`; the test asserts the event SEQUENCE (e.g. `.reachedServer` then `.joined`; a regression shows as a second `.reachedServer` at once). Pattern: OutboxServiceTests "Two concurrent first-saves of one draft create exactly one server draft".

## Gates, hangs and time limits
- A test that parks EVERY handler call on a `Gate` turns a "called too many times" bug into a HANG, not a failure. Park only the first call (`if await recorder.count == 1 { await gate.wait() }`) so extra calls record and return (found mutating `AccountTokenProvider.sessionRejected`, SessionRejectionLatchTests).
- `.timeLimit` does NOT free a non-cancellable continuation: a waiter built on `withCheckedContinuation` stored in an actor records "Time limit was exceeded" and the process then hangs forever. Use `AsyncStream` iteration (cancellation-aware) or make the waiter cancellation-aware; bound hang-prone suites with `.timeLimit(.minutes(1))`.
- A test whose calls BLOCK a thread (semaphores, a lock held across a parked call) must run them on a plain `Thread`, not `Task.detached`: starving the cooperative pool makes OTHER suites' 2 s `waitUntil`s time out under a full parallel `swift test`.

## Throwaway UserDefaults (ScratchDefaults)
- HeraldTests run inside the sandboxed Debug Herald.app, so every `UserDefaults(suiteName:)` becomes a plist in the host's container Preferences directory; `removePersistentDomain` only empties a suite and leaves the file (≈6,400 leftovers had piled up before 2f0e3ab).
- Rule: get throwaway defaults from `ScratchDefaults.make()` (or `ScratchDefaults.suiteName()` when code opens the suite itself) and put `.scratchDefaults` on the `@Suite`; the trait deletes each test's suites when it ends. Making one outside the trait records a test issue, so a missing trait fails the run.
- At host exit `cfprefsd` writes an empty plist back for every discarded suite (no in-process cleanup prevents it; an `atexit` hook made no difference). The first scratch suite of the next run sweeps `HeraldTests.*` plists older than 5 minutes (the floor protects a concurrent run in another worktree). Expect up to one run's worth (~83 empty files) between runs.
- The sweep only matches the `HeraldTests.` prefix; never delete the app's own domain, the stats domain or `com.wizemann.herald.uitest.plist` (real dev-copy / UI-test state).

## Build and run gotchas
- Adding a new test/source file needs `xcodegen generate` before xcodebuild (the generated project lists files); CLI test runs need `-skipPackagePluginValidation`. See [[Herald Build and Toolchain]].
- `swift test` on HeraldKit alone rewrites `HeraldKit/Package.resolved` and drops the app-only Sparkle pin — `git checkout HeraldKit/Package.resolved` before committing (details in [[Herald Build and Toolchain]]).
- "The test runner hung before establishing connection" / "Timed out while enabling automation mode" with otherwise green tests is runner flake (often another project's concurrent `xcodebuild test` wedging testmanagerd) — rerun when the machine is quiet.

## History
- 2026-08-16 note created (Swift Testing, discriminating tests, URLProtocol fake).
- 2026-09-26 mutation-checked gates (SessionRejectionLatchTests); `route(_:_:responses:)`.
- 2026-09-27 176efc5 Outbox flake made event-driven (300 reps under load, zero failures; mutation fails in 0.002 s); 2f0e3ab ScratchDefaults.
- Unit counts at last full green run (after U6b, c67b468/48720a9/ed2278e): HeraldTests 401, HeraldKit 449.
- 2026-09-27 UI-test knowledge (U1–U6b) split out into [[Herald UI Testing]].

## Relations
- relates_to [[Herald UI Testing]]
- relates_to [[Herald Concurrency Rules]]
- relates_to [[Herald Architecture]]
- relates_to [[Herald Build and Toolchain]]
- relates_to [[Sign-In Recoverability and the Presentation Watchdog]]
