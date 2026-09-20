# Fresh-eyes audit of the HQBase 1.4.2 adoption surface (U6, 2026-09-19)

Scope: everything touched by U1–U4 (commits 45b72a9..b16ac18 on main), old code included. Four read-only specialist passes: concurrency/sync, SwiftUI/a11y/tokens, security/API boundary, tests/SwiftData. Findings below are triaged into fix tasks F1–F4; deferred items are listed at the end.

## Confirmed, must fix before 0.5.0

| # | Area | Finding | Task |
|---|---|---|---|
| C1 | Sync | `passLabelsChanged` is drained only on the success path of `runPass`; a pass that wrote embedded labels then threw never emits `.labelsChanged`, chips stay stale until the 30-min reconciliation. | F1 |
| C2 | Sync | No pending-mutation fence on label writes. A stale `/changes` page applied after an optimistic label toggle strips the label via per-message authoritative `applyEmbeddedLabels`, and nothing re-announces it. | F1 |
| C3 | Compose | Send held by a 503 is a `.disabled` button with no reason in `.help`/a11y hint, and the ⌘⇧D "re-announce" fallback is unreachable (SwiftUI withdraws the shortcut with the control). | F2 |
| C4 | Signatures UI | Preview debounce condition inverted: every Edit sheet opens onto 250 ms of blank preview. | F2 |
| C5 | Signatures UI | Mutation error banner and field error never post an accessibility announcement (project rule). | F2 |
| C6 | Signatures UI | Preview document has no CSP meta (reading pane injects `default-src 'none'`), no `MailTheme.Web` tokens, no `prefers-contrast` handling. Preview lies about the rendered result. | F2 |
| C7 | Settings | `@State var model` on models owned by `AppEnvironment` (Signatures and Privacy panes), papered over by `.id(selectedAccountID)`; `PrivacySettingsPane` allocates a fresh model every body pass. | F2 |
| C8 | Security | `SignatureSettingsModel` logs `String(describing: error)` at `.public` (server free text), violating the payload-free `logCode` rule every other call site follows. | F2 |
| C9 | Signatures model | `save()` sets `self.editor = nil` unconditionally after an await; a save completing after the user opened a new sheet closes the new sheet. | F2 |
| C10 | App | `restoreAccounts` background activation `Task` is unretained; sign-out during it lets a purged account be re-installed with a live engine. | F3 |
| C11 | Tests | `NotificationsTests.theSettingIsHonouredPerPass` waits on `status == .idle`, already true before the event is consumed; the negative assertion is vacuous and the flip races the pass. Root cause of the board's flaky test. | F4 |
| C12 | Tests | Detail/thread → chips wiring tested only by calling `storeEmbeddedLabels` directly; deleting the two production call sites keeps the suite green. | F4 |

## Plausible, fix now (cheap) or track

| # | Area | Finding | Task |
|---|---|---|---|
| P1 | Security | Middleware logs the error body `message` at `.public` when the challenge lacks `scope=`. | F2 |
| P2 | Security | `AccountTokenProvider.currentTokens()` hides a Keychain read error behind `try?`, indistinguishable from "nothing stored"; the rotation arbiter may spend a grant another process rotated. | F3 |
| P3 | Signatures | Server advertises `signatures:manage` but issues a token without it → "Sign In Again" loops with no terminal state. | F2 |
| P4 | Sync | `labelEmbeddingAccounts` lifecycle across stop/start on a server downgrade — needs a test. | F1 |
| P5 | Tests | Action-result labels (`POST /messages/{id}/{action}` answers) not proven end-to-end through `MailActionService.perform` → store. | F1 |
| P6 | Tests | `includeLabels: true` at the single production construction site has no guard test. | F1 |
| P7 | UI | Editor sheet 720×560 inside a fixed 640×420 Settings window; fixed-height Form clips at large text sizes. | F2 |
| P8 | UI | Delete confirmation title empties mid-dismiss. | F2 |
| P9 | UI | Preview coordinator `loadTask` never cancelled on teardown; previous rule list dropped before the new one is known-good. | F2 |
| P10 | App | One `MainActor.run` where a plain `await` on the isolated method is the house style. | F3 |
| P11 | Concurrency | `WebSocketChannel.session`/`task` are `var …!` under `@unchecked Sendable` without justification. | F3 |
| P12 | UI | `updateLabelSurfaceVisibility` publishes before the engine hop completes. | F1 |
| P13 | Tests | `try? #require` idiom in one hold-message test. | F4 |
| P14 | Security | `OAuthSession` logs the callback `error` query value at `.public`; bound to a known set. | F3 |

## Structural

- `SyncEngine.swift` 1352 lines → split `+Labels` (labels region), `+Drafts`. (F1)
- `AppEnvironment.swift` 1217 lines → split `+SignIn` (onboarding through signOut), `+Compose`, `AccountGraph` own file. (F3)

## Deferred (tracked as ideas, not blocking)

- Localization-hostile string building in SignatureSettingsView, ComposeWindow ("Quoted …"), ConversationListView a11y sentence. English-only today.
- Upstream gap: no v1 route exposes the caller's user id, so a user with no personal signature cannot create the first one from any API client. File upstream.

## Clean (checked, no finding)

Label chip reaction to `.labelsChanged`; ForEach identities; idempotency keys and draft ids never logged as secrets; generated path encoding for ids; error body caps; refresh-token race handling after the scope change; Keychain debug namespace; SwiftData test hygiene (in-memory stores, no shared fake state, poll-with-early-exit waits); negative cases for <1.4.2 servers at decode, store and engine levels; 403-scope vs 404-route vs 404-row separation; SEND_KEY_CONFLICT retried exactly once; 503 holds never re-POST.
