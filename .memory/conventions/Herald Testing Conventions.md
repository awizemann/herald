---
title: Herald Testing Conventions
type: note
permalink: hqbase-mac/conventions/herald-testing-conventions
tags:
- testing
---

## Observations
- [rule] Swift Testing only (@Suite/@Test/#expect); protocol-oriented fakes injected via `nonisolated protocol`s (fake actors need it) #framework
- [rule] Tests must DISCRIMINATE: each test states (in name or comment) what broken behavior it would fail on — a test that only re-asserts what the code obviously does is a checkbox and gets removed in audit #discriminating
- [rule] Network is faked at URLProtocol level (`FakeServerProtocol`) with canned responses keyed by path, so the generated client + auth + sync run end-to-end without a server; no timing-dependent tests — poll with early exit, never sleep-then-assert #network
- [rule] App-hosted suites run Debug (ENABLE_TESTABILITY); HeraldKit tests run via `swift test` in HeraldKit/ AND through the Xcode scheme #targets
- [check] `grep -rn "static let .*= Notification.Name" --include=*.swift . | grep -v nonisolated` and `grep -rn "print(" --include=*.swift Herald HeraldKit/Sources` must both be empty #guards

## Relations
- relates_to [[Herald Concurrency Rules]]
