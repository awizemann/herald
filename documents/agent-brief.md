# Herald — agent brief (read fully before writing code)

Repo: /Users/awizemann/Developer/hqbase-mac. Native macOS client (codename Herald) for HQBase
(self-hosted Cloudflare Workers mail workspace). Read these memory notes FIRST — they are the
project's source of truth and override any generic checklist you carry:

- .memory/project/Herald Project Overview.md
- .memory/architecture/Herald Architecture.md
- .memory/architecture/HQBase Mail API v1 Contract.md
- .memory/decisions/Herald Sync Model.md
- .memory/decisions/Generated API Client Lives in Nonisolated HeraldAPI Target.md
- .memory/conventions/Herald Concurrency Rules.md
- .memory/conventions/Herald Testing Conventions.md
- .memory/conventions/Herald Error Handling and Security Rules.md
- .memory/conventions/Herald Design System and Accessibility.md
- .memory/operations/Herald Build and Toolchain.md

## Layout
- `HeraldKit/` SPM package. `Sources/HeraldAPI` = generated OpenAPI client ONLY (leaf, nonisolated
  by default; never edit generated code; spec at Sources/HeraldAPI/openapi.json). `Sources/HeraldKit`
  = all logic (builds with `.defaultIsolation(MainActor.self)` + strict concurrency). Tests in
  `Tests/HeraldKitTests` (Swift Testing).
- `Herald/` app target (SwiftUI, macOS 26, sandboxed, `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`).
  `HeraldTests/` app-hosted tests. `project.yml` is source of truth → `xcodegen generate`.

## Build / test commands (always these exact forms)
- Package: `cd HeraldKit && swift build && swift test`
- App: `xcodegen generate && xcodebuild -project Herald.xcodeproj -scheme Herald -destination 'platform=macOS' -derivedDataPath DerivedData -skipPackagePluginValidation build` (append `test` to run all suites)
- The generator's "Schema null is not supported" warnings are expected; ignore them.

## Non-negotiable rules (distilled; the notes carry the why)
1. Default-MainActor isolation: anything an actor/background context calls synchronously is
   `nonisolated`; protocols an actor conforms to are `nonisolated protocol`; `Notification.Name`
   constants are `nonisolated static let`; loggers are `private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "…")` at file scope. No `print()`.
2. `async` on a @MainActor type stays on main until first real suspension: heavy work (decode,
   HTML processing, file I/O) goes into an actor or `Task.detached { }.value` with explicit
   `@Sendable` captures.
3. Strict DTO boundary: views/view-model consume only Sendable value DTOs (`struct … : Sendable, Hashable, Identifiable`). Generated `HeraldAPI` types NEVER leave HeraldKit. `@Model` is touched only inside the `MailStore` @ModelActor.
4. Every `catch` logs (`logger.warning` expected / `logger.error` unexpected), rethrows, or returns failure. Bare `try?` only for truly ignorable ops.
5. Tokens/registration in Keychain via `KeychainStore` (never UserDefaults/logs). Redact addresses/subjects/bodies in logs.
6. Tests: Swift Testing, protocol fakes, `FakeServer` URLProtocol harness; every test names what broken behavior it fails on; no sleep-then-assert.
7. Don't over-engineer. Fewer, well-shaped types. Reuse. Read existing code before adding.

## Deliverable
Code + tests green via BOTH commands above. Finish with a concise report: files created/changed,
what each test discriminates, any deviation from the notes and why, and any gotcha worth
recording in memory (I'll write the memory note; you don't). Do NOT commit, do NOT push, do NOT
touch .memory/ TASKS.md tasks/.
