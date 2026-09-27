# Session recovery — plan (2026-09-26)

## Incident (log evidence, Herald pid 3766, 2026-09-26 13:32–13:35)
- 13:32:29 first `401 invalid_token`; refresh SUCCEEDED yet the retry with the fresh token was also 401 (live server is HQBase 1.4.0 — pre-1.4.2 session binding: the refresh endpoint mints tokens the resource server rejects once the bound web session is gone).
- 13:32:51 draft autosave 401; 13:32:59 send 401 → compose error bar showed "Your session has expired. Sign in again." with no action.
- 13:33:22–24 message detail + auto mark-read 401 — silent.
- 13:33:34 only the sync poll escalated to `.needsReauth` (35 s after the send failed).
- 13:34:11 automatic re-auth began; banner "Signing you back in…" with spinner and NO button (automatic attempts get no Cancel; hard watchdog is 10 min).
- 13:34:31 account re-added; 13:35:22 send succeeded.
- Six refreshes in ~65 s, each "successful", each spending a rotating refresh token for nothing.

## Decisions (Alan, 2026-09-26)
- Banner during an automatic attempt: **Cancel only** (cancel → cooldown → banner back to "Sign In").
- After signing in from compose: **user presses Send again** (no auto-resend).
- Work lands on **main**, one commit per phase, never pushed.
- Sidebar "Sign in again" status becomes **clickable** (same action as the banner's Sign In).

## Design principle
One chokepoint decides "this account's session is dead": the per-account `AccountTokenProvider` (already shared by REST and the wake socket). Every surface — sync, compose, detail, actions, signatures, socket — then reaches the same `MailViewModel` transition, which already drives the banner and the automatic attempt. Keep it per-account: multi-account work follows right after this.

## Phases (sequential; each: implement → real tests → fresh-eyes audit → commit on main)

### P1 — HeraldKit: dead-session latch in the token provider
- When a request is rejected (401 invalid_token) AFTER the provider supplied a refreshed/replaced token, the grant is dead: the middleware tells the provider (e.g. `sessionRejected(token:)` on `BearerTokenProvider`, default no-op for other conformers).
- The provider LATCHES "grant with refresh token R is dead": further `accessToken()`/`refreshAccessToken` calls fail fast with `OAuthError.reauthenticationRequired` WITHOUT a network refresh.
- The latch is keyed to the grant, not the provider's lifetime: if the Keychain now holds a DIFFERENT refresh token (a re-auth landed, possibly in another graph/process), the latch clears and the new tokens are used. This keeps a composer still holding the superseded graph's outbox working after re-auth.
- The provider announces the rejection ONCE per dead grant via an injectable async callback/stream (set after construction is fine) so the app can route it.
- Socket: `MailEventSocket`'s "unauthorized after a refresh" path should go through the same provider notification (it may keep its own escalate call; the app-side transition is idempotent).
- Do not clear the Keychain item on this path (unlike invalid_grant): the refresh token may be fine under 1.4.2 semantics; re-auth replaces it.
- Tests (FakeServer/URLProtocol): refresh-OK-then-401 → one notification, subsequent calls make zero token-endpoint requests; stale-401 path (token already replaced, retry succeeds) does NOT latch; a new grant in the store clears the latch; two providers (two accounts) are isolated; invalid_grant path unchanged.

### P2 — App: route every dead-session signal to the one transition
- `AppEnvironment.activate/install` wires the provider's notification to the account's `MailViewModel` transition (rename `wakeSocketRequiresReauthentication` → `reportSessionExpired` or similar; it already announces only the TRANSITION into `.needsReauth`).
- Result: a failed send/autosave/detail/mark-read raises the banner and the automatic attempt immediately, not on the next poll.
- `MailViewModel.requiresReauthentication` should also recognise `OutboxError.api(.unauthorized)` (compose uses it in P4).
- Tests: a compose/detail 401 (not the sync loop) flips status to `.needsReauth` and fires `reauthenticationRequired` exactly once; other accounts untouched; a successful re-auth clears it.

### P3 — Banner + sidebar: never a dead end
- `ReauthBanner`: during an AUTOMATIC attempt show **Cancel** (in addition to the existing user-initiated Cancel). New `AppEnvironment.cancelAutomaticReauthentication(accountID:)`: cancels `automaticReauthTasks[accountID]`, releases the `AutoReauthPolicy` claim as unsuccessful (cooldown starts), banner returns to "Sign In". Must not install the account if consent lands after the cancel (mirror the stale-generation undo in `performSignIn`).
- Sidebar status slot "Sign in again" becomes a button → `environment.reauthenticate(accountID:)` (accessible label/traits; MailTheme tokens; fixed-height slot must not reflow).
- Update the decision note "Sign-In Recoverability and the Presentation Watchdog" (#ui fact about automatic attempts having no button).
- Tests: cancel automatic → claim released with cooldown, `isReauthenticating` false, no install after late consent; VoiceOver announcement text updated.

### P4 — Compose: actionable auth failure, no lost drafts
- When send/autosave fails because the session is dead, the compose error bar offers **Sign In** → `environment.reauthenticate(accountID:)` for the composer's account (ComposeSession.accountID). On success the error clears; the user presses Send again.
- Verify and fix the composer's survival across re-auth: `install` → `closeComposeSessions` removes the session while the window keeps its model bound to the SUPERSEDED graph's `OutboxService`. Decide the cleanest correct behaviour (rebind the live composer to the new graph's outbox, or rely on P1's grant-keyed latch) and prove: text is never lost, autosave resumes, send goes through after re-auth, the Drafts cache events land on the right account.
- Tests: send 401 → Sign In action exposed; after re-auth send succeeds from the SAME window with the same content; autosave resumes.

### P5 — Verification
- Full `xcodebuild test` for app + HeraldKit (note `Package.resolved` gotcha).
- Live check against the local 1.4.2 test instance (operations note `hqbase-local-test-instance-v1-4-2`) by killing the bound session row (explicit sign-out) and confirming: banner appears immediately on a compose send, Cancel works on the automatic attempt, Sign In from compose works, no refresh storm in the log. Record whether a refresh after explicit sign-out yields a USABLE access token (corrects/confirms the API contract note).
- Never run the dev copy while /Applications/Herald.app is signed in (Build & Toolchain note).

### Final
- Orchestrator audit vs plan; memory audit (needed/redundant); fresh-eyes audit; then whole-surface audit of everything touched (auth, re-auth, banner, compose, socket, sidebar) for old and new issues → proposed fixes via the same process.
- Server: Alan to upgrade live HQBase 1.4.0 → 1.4.2 (fixes passive session-expiry binding; explicit web sign-out still revokes access tokens, so the client work stays necessary).
