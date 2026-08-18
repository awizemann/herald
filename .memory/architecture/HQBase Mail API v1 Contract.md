---
title: HQBase Mail API v1 Contract
type: note
permalink: hqbase-mac/architecture/hqbase-mail-api-v1-contract
tags:
- api
- oauth
- hqbase
created: 2026-08-16
updated: 2026-08-16
---

Verified against upstream main @ v1.1.0 (worker/auth/mail-api.ts, api/hqbase-mail-api-v1.openapi.json).
Vendored copy of the spec lives at HeraldKit/Sources/HeraldKit/openapi.json (refresh from
`{origin}/api/v1/openapi.json` or upstream repo `api/`).

## Observations
- [fact] Routes: GET mailboxes; GET messages (filters folder/mailboxId/search — bare array, NO pagination); GET messages/{id} /thread /html /inline/{att}; GET attachments/{id}; POST messages/{id}/{action} action∈read,unread,star,unstar,archive,trash; POST messages/{id}/remote-media/trust; GET conversations (paged via cursor; the v1 spec exposes NO limit param — server-side page size ~50); POST conversations/{id}/{action}; drafts CRUD + POST drafts/{id}/attachments (multipart) ; POST send; POST reply #routes
- [constraint] Bearer tokens are AUDIENCE-BOUND: request `resource={origin}/api/v1` on BOTH the authorize and token calls or the token is rejected (401 INVALID_OAUTH_TOKEN); tokens minted for /mcp or /mcp/full do not work on /api/v1 #oauth
- [fact] OAuth: discovery at /.well-known/oauth-authorization-server (issuer {origin}/api/auth); dynamic client registration allowed unauthenticated (public client, token_endpoint_auth_method none); scopes mail:read mail:write mail:send offline_access; PKCE authorization_code + refresh; device flow also exists (verification at /device) #oauth
- [fact] Scope→route: mail:read = mailboxes/messages/conversations/attachments/html/inline; mail:write = message+conversation actions and remote-media trust; mail:send = ALL drafts routes + send + reply #scopes
- [fact] Errors are `{error:{code,message}}`; 401 carries `WWW-Authenticate: Bearer resource_metadata="{origin}/.well-known/oauth-protected-resource/api/v1", scope="…", error="invalid_token|insufficient_scope"`; server has NO delta/changes endpoint and NO push except browser Web Push (VAPID) → client polls #contract

## Relations
- relates_to [[Herald Architecture]]
- relates_to [[Herald Sync Model]]

## Update (2026-08-15 — spec details found in P0.1)
- [fact] Conversations use a DIFFERENT folder enum than messages (`starred` instead of `drafts`) → separate `ConversationFolder` DTO enum; conversation actions REQUIRE `folder` in the request body (400 without) #conversations
- [fact] Draft PATCH is optimistic-concurrency: send the draft's version stamp (`editableContent`) or the server 409s #drafts
- [fact] Multipart draft attachment `file` part declares no per-part headers, so MIME type can't be sent; inline image responses don't surface Content-Type — client sniffs magic bytes #binary

## Update (2026-08-15 — OAuth discovery/registration verified against upstream)
- [fact] Authorization-server metadata URL is RFC 8414 path-suffixed: `{origin}/.well-known/oauth-authorization-server/api/auth` (issuer `{origin}/api/auth`); protected-resource metadata `/.well-known/oauth-protected-resource/api/v1` advertises `authorization_servers:["{origin}/api/auth"]` #discovery
- [fact] Dynamic registration: POST returns 201; body should carry `resources:["{origin}/api/v1"]`, `token_endpoint_auth_method:"none"`, grant_types authorization_code+refresh_token, and an explicit `scope:"mail:read mail:write mail:send offline_access"` (upstream test confirms all four come back); consent UI at `/oauth/consent` #registration
- [fact] Server also documents a Device Authorization flow for CLIs/agents at `/AGENTS.md` per instance — Herald uses PKCE, but a future CLI can reuse HeraldKit's Auth/ with the device grant #device

## Update (2026-08-15 — drafts/send facts from P0.5)
- [fact] Attachment limits (server, worker/features/drafts/queries.ts:167): 25 MiB per file AND 25 MiB per-draft total → 413 ATTACHMENTS_TOO_LARGE; the client enforces a stricter injectable 10 MiB per-file default and does NOT yet enforce the per-draft total (follow-up) #attachments
- [fact] `SendInput.draftId` / `ReplyInput.draftId` exist — send/reply consume the server draft; explicit delete afterwards is best-effort/404-tolerant; draft PATCH conflict = 409 code DRAFT_CONFLICT (client refetches + retries once, then `.draftConflict`) #drafts
- [fact] No forward route: forward = draft with `forwardOfMessageId` sent via POST /send (recipients required); reply with empty `to` lets the server pick original reply targets #forward
- [gotcha] REAL-SERVER 2026-08-15: registration must send `application_type: "native"` or the server replies "web clients require https redirect URIs on non-loopback hosts" for `herald://oauth/callback` (RFC 7591 client classification) #registration
- [gotcha] REAL-SERVER 2026-08-15: native redirect URIs must be RFC 8252 §7.1 — reverse-domain scheme, NO authority (`com.wizemann.herald:/oauth/callback`, not `herald://…`); the ASWebAuthenticationSession callbackURLScheme is `com.wizemann.herald` #redirect
- [gotcha] REAL-SERVER 2026-08-15: POST /reply and forward-via-/send APPEND attribution + quoted original server-side (worker/features/send/reply-body.ts, forward.ts) — the client must send ONLY the authored text; ComposePrefill.quotedBody remains for display purposes only #quoting
- [gotcha] REAL-SERVER 2026-08-15: `POST /conversations/{id}/{action}` — `{id}` is a MESSAGE id (server calls getMessageMailboxId(id) for the access check and derives the thread); `ConversationSummary.id` upstream IS the latest message id with `threadId` separate. Herald keys conversations by threadID internally and MailActionService sends the newest member message id on the wire. The v1 spec does not document this — reported upstream as a spec gap #conversation-actions
- [fact] Access levels: read/unread need mailbox access "read"; star/unstar/archive/trash need "agent"; owner role ⇒ manager everywhere (worker/auth/mailbox-access.ts) #access
- [fact] Folder enums are asymmetric by exactly one member each: MESSAGE folders have `drafts` (no conversation folder), CONVERSATION folders have `starred` (no message folder). `SyncFolder` therefore has two optional halves; the default scope walks `starred` conversations and requests no starred message list (which would 400) #folders
- [gotcha] SERVER-CODE 2026-08-16: `GET /api/v1/messages` SILENTLY caps at 100 rows (queries.ts `LIMIT` clamped 1..100, no limit/cursor param exposed, not in the spec). SyncEngine treats a response of exactly `serverMessageListCap` (100) as truncated and skips tombstoning; busy folders show newest-100 in cache until upstream PR3 (pagination + updatedSince). `messages.updated_at` exists and is bumped on state changes (unindexed) — the natural delta key #cap
- [fact] TOKEN LIFETIMES (server 1.1.x, better-auth 1.7.0-rc.6 defaults, none overridden): access token 1h (Herald refreshes silently), refresh token 30d, BUT every token is bound to the browser session that approved it (oauth-principal.ts joins `session` and rejects when sessionExpiresAt ≤ now; refresh keeps the same session id). That web session lasts 7d and slides only on browser use; web-app Sign Out kills it instantly → Herald shows needsReauth. Not fixable client-side; upstream follow-up: let refresh_token renew the bound session or bind native tokens to the user #session-binding
- [gotcha] REAL-SERVER 2026-08-17 (ROOT CAUSE of "logged out after a few hours" + Herald #1): protected-resource `scopes_supported` is ONLY the API permissions (mail:read/write/send) — `offline_access` is deliberately absent. A client that requests exactly the advertised set gets NO refresh token and dies at the 1h access-token expiry. Herald now always adds `offline_access` (`OAuthDiscovery.alwaysRequestedScopes`); the test fake mirrors the real metadata. Fixed in v0.1.3; existing accounts need one re-sign-in #offline-access
- [fact] CHANGES FEED (upstream #37, 2026-08-18): `GET /api/v1/changes?cursor&limit` → `{changes:[{type:"upsert",message}|{type:"delete",messageId,mailboxId}], nextCursor (NON-optional — end signal is hasMore=false, unlike ConversationPage), hasMore}`; no cursor = checkpoint (empty changes + high-water cursor); 400 INVALID_CHANGE_CURSOR / INVALID_CHANGE_FILTER (any mailboxId/folder/search filter is rejected); 410 CHANGE_CURSOR_EXPIRED matched on the BODY code; journal written by DB triggers on message insert/update/delete; tombstones carry mailbox_id for auth #changes
- [fact] PAGINATION (upstream #35): GET /messages `limit` 1–100 (default 100), opaque versioned `cursor` ("m1"), `Link: <url>; rel="next"` header absent on the last page; 400 INVALID_LIMIT / INVALID_CURSOR #pagination
- [gotcha] ROOT CAUSE #3 of "logged out after hours" (2026-08-18, from logs): refresh tokens ROTATE on every refresh with NO reuse grace (`refreshTokenReuseInterval` unset → 0) and reuse of a rotated token triggers FAMILY INVALIDATION (all refresh tokens for client+user revoked → invalid_grant). Two Herald processes sharing one keychain (release + dev copy) refreshed the same token 13 ms apart → both dead within the hour; Herald then deleted the shared item on invalid_grant. Upstream issue HQBase/hqbase#41 asks for a small reuse interval; client fix = re-read-and-compare before refresh/retry and before treating invalid_grant as terminal #rotation
