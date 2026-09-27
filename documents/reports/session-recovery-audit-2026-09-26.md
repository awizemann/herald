# Session recovery — final audit (2026-09-26)

Commits: 173d5a0 (P1), 74ca7b6 (P2), 9cead5e (P3), f3a2255 (P4). Plan: documents/plans/session-recovery-2026-09-26.md. Manual UI checklist: documents/reports/session-recovery-manual-checklist-2026-09-26.md.

## Plan vs delivered
All P1–P5 items delivered. Tests: app 319 / HeraldKit 380 green (one load-dependent outbox timing flake, green on rerun). Server repro (local 1.4.0 / 1.4.2) confirmed the incident: on 1.4.0 a dead web session → refresh 200, fresh token 401, forever. 1.4.2 fixes passive expiry AND web sign-out (refreshed token works) — correction of the plan's assumption. Latched Keychain grant stays valid → after the prod upgrade a relaunch recovers without Sign In.
Extra fix found in P3: cancelling a late re-auth consent used to sign the whole account out of the Keychain.

## Fresh-eyes audit of the diff (read-only)
No crash/deadlock/permanent stuck state found. Findings:
- D1 (high, identity) a consent from a DIFFERENT HQBase user is adopted silently: Account.id == origin, so the "different id" branch never fires; P3's keep-late-consent widens it. → multi-account (identity by origin+sub).
- D2 latch can fire on false positives: a 401 with no challenge / one misbehaving route latches the whole grant. → latch only on explicit error="invalid_token" (server always sends it — verified in P5).
- D3 kept late consent: account works but banner/compose still say dead; after cooldown the automatic flash re-opens. → install with select:false in the keep branch.
- D4 composer rebind can create a duplicate server draft (create dedupe is per-outbox). → serialize saves/creates in the composer.
- D5 one account's Sign In cancels another account's interactive sign-in. → multi-account (global one-window rule).
- D6 handler installed late → a death in the gap is recorded as announced but never delivered. → set handler in activate.
- D7 orphaned cancelled attempt can overwrite a newer grant (low).
- D8 concurrentReportsAnnounceOnce claims more than it tests. D9 nothing tests that activate wires the provider.
- Nits: banner cancelledByUser leaks across accounts; signed-out composer "Save Draft" is silent; isCancellableReauthentication test-only; signOut awaits a possibly wedged automatic attempt.

## Whole-surface audit (read-only, old + new code)
- W1 (high) identity keyed by origin: Add Account for an existing origin as another user replaces the account, composers rebind to the other user, caches mix. → now: refuse Add Account for an existing origin; multi-account: origin+sub identity, merge-not-replace store.add.
- W2 (high) unreadable account index is treated as empty then OVERWRITTEN on next add → all other accounts lost, refresh tokens orphaned. → tolerant Account decoding; add/remove throw instead of overwrite. Before multi-account.
- W3 (high) refresh errors other than invalid_grant (invalid_client, unauthorized_client, http_401…) → "Sync problem"+useless Retry, token endpoint hit every pass, no banner; stale client_id never re-registered. → treat as dead grant + clear client_id.
- W4 activation needs network discovery → offline launch shows "could not start"; failed secondary account vanishes from UI. → persist/lazy discovery now; placeholders later.
- W5 failed manual re-auth shows no reason (signInError only shown in onboarding). → per-account reauthError in banner + compose.
- W6 unselected account's dead session is invisible (no marker, stale badge). → multi-account.
- W7 two consent windows for two accounts at once. → multi-account (global gate).
- W8 re-auth steals window selection to the re-authed account. → activate(select: graphs[id] == nil).
- W9 sign-out can hang behind a wedged automatic attempt. → cancel, don't await.
- W10 latch/stopped sync never self-heal while running (server upgrade, other process re-auth). → low; probe on activation.
- W11 stale empty-store report can raise the banner on a fresh graph right after re-auth. → re-check grant before announcing.
- W12 Signatures pane retry flag reset by re-install (loop / lockout). W13 notifications for signed-out accounts never withdrawn.

## Proposed follow-up (same process: phase task → sub-agent implement/test/audit → commit)
- P6 Hardening of this work: D2, D3+W8, D6+D9, D4, W9, W11, D8, nits.
- P7 Actionable failures: W3, W5.
- P8 Account-store safety + offline launch: W1 guard, W2, W4 (persisted/lazy discovery).
- Multi-account project inputs: D1/W1 identity (origin+sub), W6, W7/D5, W4 placeholders, W10, W12, W13.
