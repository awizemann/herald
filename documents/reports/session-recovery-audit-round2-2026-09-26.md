# Session recovery — round-2 audit (2026-09-26)

Scope: 9b3101c (P6), 649f8f4 (P8), f243925 (P7). Three read-only reviews: P7's own late reviewer, fresh-eyes diff audit of P6–P8, whole-surface re-audit at HEAD.

Status of round-1 items: D2, D3+W8, D4, D6, D8, D9, W3, W4, W5, W9, W11 FIXED; W1/W2 partial (in-process OK; identity + cross-build writers remain → multi-account); D1, D5/W7, W6, W10, W12, W13 deferred; D7 accepted residual.
Goal check: met for the selected account (prompt banner, Cancel always, reason on failure, compose Sign In, no text loss, no refresh storm). Gaps below.

## Fix now → P9a (HeraldKit auth)
- A (high, all three reviews) provider captures clientID at build; after a re-registration (other process / superseded provider) it refreshes the current grant with the OLD client → false latch+banner, or invalid_grant wipes the shared healthy grant. Resolve clientID at refresh time (store.account(id:)); treat a refusal sent with a non-current clientID as superseded.
- B bare 401 from the token endpoint (`http_401`) is terminal → one proxy blip = banner + consent window until relaunch. Make it non-terminal/non-latching (retry like transport), consistent with P6's API-side rule.
- C `invalid_scope`/`invalid_target` → re-auth reuses cached discovery + scope-bound registration and can never succeed. Clear discovery (memory + persisted) and the registration before announcing.
- F dead registration while no account on the origin (client.<origin> survives sign-out) → every Sign In lands on the server error page, no in-app exit. Forget client.<origin> on sign-out when no remaining account uses the origin.
- H sign-out bumps the per-origin generation after the revoke round trip → a provider can rotate during it, orphaning a live grant. Bump/evict/cancel before revoking.
- I refresh refused by the sign-out generation (`unknownAccount`) maps to transport "Sync problem" forever → map to a re-auth death.
- Nits: `forgetClientID` doc claims serialization that `setClientID` lacks (lock both or fix doc); `unauthorized_client` for a client registered in the same attempt must not forget/reword (report whether this attempt registered).

## Fix now → P9b (app)
- D (N1) automatic re-auth can loop when a non-challenge 401 keeps escalating (success clears the cooldown). Rate-limit automatic attempts regardless of outcome.
- E (N2/W10) `.needsReauth` never self-heals (other build re-authed, non-death 401). Before an automatic attempt (and on activation), probe `SessionDeath.isCurrent()` / stored grant; if the grant is healthy, restart the engine and clear the status instead of opening consent.
- G invisible failures: Add Account activation failure after consent (sheet already closed; didSet clears the error); sign-out failure with accounts remaining (N4). Surface them (keep sheet open until installed / alert).
- J composer: overlapping saves after rebind can leave a stale server draft with no re-save → reschedule autosave when still dirty after a save; `send()` needs a pre-wait sending guard (double click during create wait).
- K W12 comment at SignatureSettingsModel.swift:152 is false (flag does not survive re-auth) — correct it (fix itself deferred to multi-account).
- Nits: VoiceOver double announcement (composer + banner) of one failure; `presentsAddAccount` didSet should clear stale signInError when no re-auth is running (`signInReauthAccountID == nil`); corrupt index → onboarding with an explanation.

## Multi-account inputs (added to the multi-account task)
Identity source needed (no /me or id_token in v1 contract; `addAccount` persists before identity can be checked) — keep ids stable (tokens.<id> is the cross-process arbiter), store identity as a separate item older builds never rewrite; per-origin sign-out state (generation, discovery eviction, client forget, Add Account guard) must become per-account/"last account on origin"; cross-build index writers can lose updates; persist account order; "mail to check" indicator for non-selected accounts (collapsed picker shows only the selected account; dead background accounts freeze counts/notifications silently); global single consent window queue; Dock badge semantics; withdraw signed-out notifications.
