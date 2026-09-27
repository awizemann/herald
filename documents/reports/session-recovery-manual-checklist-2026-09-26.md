> **Superseded for running (2026-09-27):** most of these checks are now automated XCUITests. The manual-only remainder is `reports/session-recovery-manual-checklist-v2-2026-09-27.md`. Keep this file for the kill-the-session table and the server-version notes.

# Session recovery: manual UI checklist (P1–P4)

Written 2026-09-26 during P5 verification (plan `documents/plans/session-recovery-2026-09-26.md`). Commits covered: 173d5a0 (P1 latch), 74ca7b6 (P2 routing), 9cead5e (P3 Cancel / sidebar / sticky banner), f3a2255 (P4 compose Sign In). The automated suites pass. These checks cover the UI, which the automated tests cannot reach.

## Before you start

- **Quit /Applications/Herald.app.** The dev copy has its own Keychain item (`com.wizemann.herald.debug`), but both copies claim the `com.wizemann.herald:` callback scheme, so an open release app can take the sign-in callback. Alternatively, run the checklist on the next release build.
- **Herald accepts `https` servers only** (`AppEnvironment+SignIn.swift` and `OAuthDiscovery` reject `http`). The local wrangler instances run on `http://localhost` and **cannot be used from the app** unless you put an https front on them. Plan on testing against production (1.4.0 today).
- Keep a log stream open: `log stream --predicate 'subsystem == "com.wizemann.herald" AND process == "Herald"' --level info`

## How to kill the session (what each method triggers)

| Server | Method | What Herald sees | Path exercised |
|---|---|---|---|
| **1.4.0 (production today)** | Sign out of HQBase in the browser that approved Herald's consent | Old token 401 `invalid_token`, refresh **200**, new token **401** | P1 latch, then banner |
| 1.4.0 | Let the 7-day web session lapse | Same as sign-out | P1 latch |
| **1.4.2** | Sign out in the web app | Old token 401, refresh 200, **new token 200** | **Silent recovery, no banner.** Sign-out is not a test method on 1.4.2 |
| 1.4.2 | Revoke Herald's grant (a connected-apps UI if HQBase has one, or SQL: `UPDATE oauthRefreshToken SET revoked=…`) | Refresh 400 `invalid_grant` | invalid_grant path (Keychain cleared, then banner) |
| 1.4.2 (local, SQL only) | Remove `offline_access` from `oauthConsent.scopes` and set `session.expiresAt` in the past | Refresh 200, new token 401 | P1 latch |

Warning: on 1.4.0, signing out of the web kills **every** Herald grant that browser session approved, including the release app's. Expect the release app to need Sign In too.

## Checks

### 1. Compose send with a dead session (P1 + P2 + P4)
1. Sign the dev copy in to production. Open a compose window, address it to yourself, and type a body.
2. Kill the session (1.4.0: web sign-out).
3. Press Send.
   - [ ] The main-window banner appears **right away** ("Your session expired. …"). It should not wait for the next sync poll.
   - [ ] The compose error bar shows **Sign In**, not just text.
   - [ ] The log shows **at most one** refresh followed by "session rejected after refresh … grant latched". There should be no repeated refreshes (the incident showed six in 65 s).
   - [ ] Typing in the body does not clear the error or start autosave 401s.

### 2. Cancel during the automatic attempt (P3)
1. With Herald frontmost at the moment of expiry, the automatic attempt starts: "Signing you back in…" with **Cancel**.
2. Press Cancel.
   - [ ] The web sheet closes, and the banner returns to "Sign in again to keep syncing." with a **Sign In** button right away. It should not wait for the 10-minute watchdog.
   - [ ] Press Sign In immediately after Cancel. It works, and the stale attempt does not steal or undo it.
   - [ ] Quit and relaunch after the Cancel. The account is still listed; a Cancel must not delete the Keychain account.

### 3. Sidebar "Sign in again" (P3)
- [ ] The account row's status "Sign in again" is a clickable button that starts re-auth.
- [ ] The button is disabled while an attempt is running.
- [ ] A non-auth sync failure afterwards does not replace the "Sign in again" state.

### 4. Composer survives re-auth and sends (P4)
1. From the compose window's **Sign In** (step 1), complete the web consent.
   - [ ] The compose window stays open with its text, recipients, and attachments intact.
   - [ ] The error clears, and VoiceOver or the status says "Signed in again. Press Send to send your message."
   - [ ] Nothing sends automatically. Press Send once and the message arrives exactly once (the idempotency key is kept).
   - [ ] Autosave resumes (the draft updates on the server/web).
2. Variant: re-auth from the **main banner** instead of the composer. The open composer is rebound the same way.
3. Variant: sign the account **out** while a composer is open. Send is blocked with a reason (tooltip), and the text stays in the window.

### 5. VoiceOver (turn it on with Cmd-F5)
- [ ] When the banner appears, VoiceOver announces "Your session expired. Use the Sign In button in the banner to keep syncing." During an automatic attempt it says "…Signing you back in… Use the Cancel button in the banner to stop."
- [ ] Cancel is read as "Cancel sign-in". After a Cancel, VoiceOver says "Sign-in cancelled. Use the Sign In button in the banner when you're ready."
- [ ] The banner icon is not read aloud (it is decorative).
- [ ] Compose Sign In is reachable by keyboard and VO. While signing in, it reads "Signing in to this message's account".
- [ ] The sidebar "Sign in again" button is reachable and read as "Sign in again".

### 6. Relaunch after a latch (expected behaviour)
- [ ] The latch is kept in memory only. Relaunching while still dead does exactly one refresh, then latches again (no storm).
- [ ] **After production is upgraded to 1.4.2**, a relaunch alone should recover a grant latched under 1.4.0, with no Sign In needed. This was verified at HTTP level: the latched refresh token keeps working and the 1.4.2 server accepts its new tokens.
