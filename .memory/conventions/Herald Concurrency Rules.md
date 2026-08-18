---
title: Herald Concurrency Rules
type: note
permalink: hqbase-mac/conventions/herald-concurrency-rules
tags: [swift6, concurrency]
created: 2026-08-16
updated: 2026-08-18
---

Both targets build with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor (Swift 6.2 approachable
concurrency) and strict concurrency. Every unannotated top-level decl is implicitly @MainActor.

## Observations
- [rule] Anything an actor / background task must call synchronously is `nonisolated` (funcs, static lets, `Notification.Name` constants); protocols an actor conforms to are `nonisolated protocol` (why: implicit MainActor isolation otherwise → "actor cannot conform to global-actor-isolated protocol"; bites hardest in test fakes) #isolation
- [rule] `async` on a @MainActor type stays ON MAIN until the first real suspension — blocking work (file I/O, JSON decode of big bodies, HTML processing) goes in `Task.detached(priority:.userInitiated){}.value` with explicit @Sendable capture, or in an actor (why: the dominant perf defect class is main-thread blocking) #main-thread
- [rule] `os.Logger` at file scope as `private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category:)` — nonisolated (not plain let, not nonisolated(unsafe)); no print() outside #Preview/tests #logging
- [rule] @Observable class holding a lock/flag: `@ObservationIgnored nonisolated(unsafe) var` and ignore Xcode's "no effect" warning — it is a false positive; plain nonisolated fails on the macro's mutable storage; use os_unfair_lock for flags #observable
- [rule] All closures passed to Task / Task.detached / withCheckedThrowingContinuation are @Sendable; non-Sendable framework types (WKWebView, NSWindow) stay on main and any documented `nonisolated(unsafe)` bridge is recorded in memory so audits don't "fix" it #sendable

## Relations
- relates_to [[Herald Architecture]]
- relates_to [[Herald Testing Conventions]]

## Update (2026-08-15 — extensions on nonisolated protocols)
- [gotcha] `nonisolated` on a protocol does NOT propagate to `extension Proto { }` — under default-MainActor isolation the extension's helpers become @MainActor and an actor can't call them synchronously ("call to main actor-isolated instance method in a synchronous nonisolated context"). Write `nonisolated extension Proto { }`. Found in SecretStore during P0.2 #extensions
- [check] `grep -rn "^extension .*Store\|^extension .*Client\|^extension .*Provider" HeraldKit/Sources | grep -v nonisolated` — review each hit #guards

## Update (2026-08-15 — sanctioned AppKit bridges)
- [fact] `WindowCloseInterceptor.previous` is `nonisolated(unsafe) weak` because it overrides nonisolated NSObject forwarding (`responds(to:)`/`forwardingTarget(for:)`); only main-actor attach/detach write it and AppKit delivers delegate messages on main — SANCTIONED, do not "fix" #appkit-bridge
- [fact] Sync cadence is driven by NSApplication didBecomeActive/didResignActive (app-level), not per-window scenePhase — a second window (compose) flipped scenePhase and idled the sync #cadence

## Update (2026-08-15 — real-run crash: framework callbacks)
- [gotcha] CRASH CLASS: under default-MainActor isolation, a closure literal passed to a framework API whose parameter is NOT declared @Sendable (e.g. `ASWebAuthenticationSession(url:callbackURLScheme:completionHandler:)`) is inferred @MainActor; when the framework calls it off-main the runtime traps in `dispatch_assert_queue` (EXC_BREAKPOINT, `_swift_task_checkIsolatedSwift`). Rule: write `{ @Sendable args in Task { @MainActor in … } }` for EVERY framework completion handler that may fire off-main. Audit any new AppKit/WebKit/AuthenticationServices/URLSession-delegate closure for this #callback-isolation
- [check] `grep -rn "completionHandler\|) { [a-zA-Z_, ]* in" --include=*.swift HeraldKit/Sources Herald | grep -v "@Sendable"` — review each framework callback hit #guards


## Update (2026-08-18 — os_unfair_lock over actor for sync nonisolated stores)
- [decision] `KeychainAccountStore` guards its account-index read-modify-write with `OSAllocatedUnfairLock` (os_unfair_lock), NOT an actor. `AccountStore` is a deliberately SYNCHRONOUS `nonisolated protocol: Sendable` so the `AccountTokenProvider` actor and test fakes call it synchronously off-main; making the impl an actor forces the whole protocol async and ripples through the auth path + every fake. Rule: a type behind a sync nonisolated protocol serializes shared state with os_unfair_lock, not by becoming an actor (commit 9df695d, t-e2af8452) #locks
- [gotcha] Standards-audit guidance "prefer actor for shared mutable state" does NOT apply when the type must satisfy a sync nonisolated protocol — os_unfair_lock is the sanctioned primitive there (04 §1 already names it over NSLock) #audit
