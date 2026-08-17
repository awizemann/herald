# Herald audit brief (read-only specialists)

You are auditing /Users/awizemann/Developer/hqbase-mac. READ-ONLY: do not edit files. Read
documents/agent-brief.md and ALL memory notes it lists (including appended "Update" sections) —
these are the project's standard and they OVERRIDE your generic checklist wherever they conflict.
Specifically:
- Both targets build with SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor + strict concurrency. Missing
  `@MainActor` is NOT a finding; MISSING `nonisolated` (on protocols actors conform to, on
  extensions of those protocols, on helpers/static lets/Notification.Name used from actors) IS.
- `@ObservationIgnored nonisolated(unsafe)` on a lock/flag in an @Observable class is CORRECT.
- Logger convention: `private nonisolated let logger = Logger(...)` at file scope.
- Generated code in HeraldKit/Sources/HeraldAPI is out of scope (never edited).
- This is macOS: think Full Keyboard Access, menu Commands, windows, sandbox, Keychain, WKWebView.
  Drop iOS-only advice.
- Assume the code is wrong and try to prove it against the actual source; every finding must
  cite file:line, severity (critical/high/medium/low), concrete impact, and a specific fix. Skip
  style nits. Also review the TESTS for discriminating power where relevant to your lens.
Report as a compact list, most severe first, then a one-paragraph overall verdict.
