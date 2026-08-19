---
created: 2026-08-19
updated: 2026-08-19
source_sha: 35ba57be0606d427a5aa36e1500b7f685b444351
source_paths: HeraldTests, HeraldKit/Tests/HeraldKitTests
source_paths_inferred: false
---

# Testing and Quality

Herald uses Swift Testing (not XCTest). Tests are organized by feature, with injected fakes for all dependencies.

## Test structure

- `HeraldTests/` — App-level tests (view models, compose, notifications, analytics)
- `HeraldKit/Tests/HeraldKitTests/` — Kit-level tests (sync, auth, API, drafts)

Test suites use the `@Suite` / `@Test` macro syntax. Each test file is a struct with test methods.

## Testing conventions

Swift Testing conventions:

- Swift Testing only (`@Suite` / `@Test` / `#expect`); no XCTest
- Protocol-oriented fakes (injected via `nonisolated protocol`s)
- Protocols meant to be adopted by fakes are declared `nonisolated protocol … : Sendable`
- No mocking frameworks; hand-written fakes
- Assertions use `#expect(condition)`, not `XCTAssertTrue`

## Common fakes

- `FakeMailAPIClient` (`HeraldKit/Tests/HeraldKitTests/Sync/FakeMailAPIClient.swift:9`) — Records calls and returns fixtures
- `FakeServer` (`HeraldKit/Tests/HeraldKitTests/Support/FakeServer.swift:55`) — URLProtocol-based fake HTTP server
- `FakeTokenProvider` (`HeraldKit/Tests/HeraldKitTests/Support/FakeTokenProvider.swift:8`) — In-memory account and token store
- `FakeOutbox` (`HeraldTests/ComposeViewModelTests.swift:10`) — Records sent messages

## Running tests

From Xcode, select the test target and press Cmd+U.

From the command line:

```sh
xcodebuild test -project Herald.xcodeproj -scheme Herald -destination 'platform=macOS' -derivedDataPath DerivedData
```

The Herald scheme runs both `HeraldTests` and `HeraldKitTests` (roughly 370 tests today). Analytics tests run inside the sandboxed host, so they use throwaway app ids and temp queue directories — never the production `UserDefaults` suite.

## Discriminating tests

Tests are "discriminating" — they exercise a real feature end-to-end using fakes at the boundary, not mocks scattered throughout. For example:

- An auth test uses a real `AuthCoordinator` with a `FakeAuthorizationPresenter`
- A sync test uses a real `SyncEngine` with a `FakeMailAPIClient`
- A view-model test uses a real `MailViewModel` with a `FakeMailAPIClient` and `FakeOutbox`

This style catches integration bugs that mocks would hide.

---
_Last updated: 2026-08-19 — testing and quality runbook; fact-checked against the code for v0.3.0_