Title: OAuth: access tokens die with the browser session that approved them, so a native client signs out roughly weekly no matter how active it is

Design discussion, offering to implement whichever shape you prefer. This is the remaining root cause behind the "logged out after hours/days" reports; #41 (`refreshTokenReuseInterval: 30`, `worker/auth/auth.ts:132`) fixed the other one and that class is genuinely gone.

## What exists

Bearer authentication joins the browser session row and rejects on its expiry:

```ts
JOIN "session" s ON s.id = at.sessionId AND s.userId = at.userId
…
const sessionExpiresAt = Date.parse(row?.sessionExpiresAt ?? "");
if (… || !Number.isFinite(sessionExpiresAt) || sessionExpiresAt <= now) throw new OAuthBearerError();
```

(`worker/auth/oauth-principal.ts:54`, `:62`, `:68-70`.)

`createAuth` passes no `session` block (`worker/auth/auth.ts`), so better-auth's defaults apply: `expiresIn` 7 days, `updateAge` 1 day (`better-auth/dist/context/create-context.mjs:145-147`), and the slide happens in `getSession` (`better-auth/dist/api/routes/session.mjs:172-173`) — i.e. only when a **browser** presents the cookie.

Refreshing does not escape it. The refresh grant reuses the stored session id verbatim and never checks whether that session is still alive: `handleRefreshTokenGrant` validates the refresh token's own expiry and resources, then calls `createUserTokens(… sessionId: refreshToken.sessionId …)` (`@better-auth/oauth-provider/dist/introspect-*.mjs:2100-2184`). So the token endpoint happily returns `200` with a fresh access token, and the very next `/api/v1` call 401s on the join above.

Worth noting the library itself intends the opposite: its back-channel-logout planner deliberately spares `offline_access` refresh tokens "so long-lived API access can outlive the browser session" (`@better-auth/oauth-provider/dist/authorize-*.mjs:208-221`). HQBase's own `oauth-principal` join is what puts that lifetime back under the cookie.

## Why it matters for a native client

A native client never opens the browser after consent. Herald talks only to `/api/v1` — mailboxes, messages, drafts, send, labels, the `/events` socket — so nothing it does can slide the bound session. The session therefore expires on a wall clock: at most seven days after consent, regardless of how heavily the app is used. Every install signs out weekly, and the more exclusively someone uses the native client instead of the web app, the more reliably it happens.

From the user's side there is no signal that anything is wrong until a request fails; from ours there is nothing to fix client-side, because the credential we hold is valid and refreshable — it just isn't accepted.

We ship a mitigation: when the app is frontmost, Herald re-runs the consent flow automatically, rate-limited per account, with a banner as the fallback. The window flashes once and completes against the still-live cookie session, so most users see a blink rather than a sign-in. It's workable, but it is not a fix — it depends on a browser cookie session that itself lapses on the same 7-day clock, and when both have lapsed the user gets a full interactive sign-in with no warning. It also means the app periodically steals focus, which is exactly the kind of thing a mail client shouldn't do.

## Options

No strong stance on which — they trade off differently against how you want revocation to work.

1. **Let the refresh grant renew or extend the bound session.** On a successful `refresh_token` grant for a token holding `offline_access`, push the session row's `expiresAt` out by the normal `expiresIn` (or mint a successor session and repoint the token family). Smallest change, keeps every existing revocation path working unchanged (deleting the session still kills the tokens, `oauth-principal.ts:54` still enforces it), and matches what the library's logout planner already assumes. The question it raises is whether a native client refreshing in the background should be able to keep a *browser* session alive indefinitely — arguably it shouldn't, which is why a successor session dedicated to the grant might be cleaner than sliding the original.

2. **Bind tokens issued to native clients to the user, not the session.** Registration already classifies clients (`application_type: "native"` is required for a non-HTTPS RFC 8252 redirect URI), so the classification exists at consent time. For those clients, drop the session join from `authenticateOAuthBearer` and rely on the consent row plus the token family for revocation — `oauthConsent` is already joined (`oauth-principal.ts:47`) and already gates scopes and resources (`:88-93`), so "revoke this app" stays effective and immediate. Larger conceptual change: it makes app authorization outlive browser sign-out, which is what desktop mail clients normally do, but it is a real policy shift and needs a visible "connected apps / revoke" surface to be honest.

A third, weaker option is just raising the session `expiresIn` for the OAuth path — it moves the problem rather than solving it, and we'd rather not ask for that.

## Open question

Is the session join intended as the revocation mechanism, or is it incidental (the natural thing to write given better-auth's schema)? If it's load-bearing — i.e. "signing out of the web app must kill native clients too" is a deliberate security property — then option 2 is off the table and option 1 needs to preserve it, and we'd rather design around that than argue with it. If it's incidental, option 2 is the smaller long-term surface.

Happy to implement either, with tests covering: refresh after the bound session has expired, revocation via the consent row, and a native token surviving a web-app sign-out (or not, depending on which way you decide).
