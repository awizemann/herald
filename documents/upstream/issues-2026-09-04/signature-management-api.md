Title: Mail API: signature CRUD on `/api/v1` — clients can read and apply signatures but not manage them

Design proposal, offering to implement.

## Where things stand

`GET /api/v1/signatures?from=<address>` (scope `mail:send`) already exists and is genuinely good: it returns `{automaticSignatureId, signatures[]}` scoped to what's usable from that exact From address, and `DraftInput`/`SendInput`/`ReplyInput`/`ForwardInput` all accept a `signature: SignatureSelection` (`{mode:"automatic"}` | `{mode:"selected", id}` | `{mode:"none"}`) that the server resolves and appends server-side (`worker/features/signatures/service.ts:19-56`, `worker/features/send/body.ts`). A client never touches signature HTML directly. That's the right contract for *sending*.

What's missing is everything upstream of that: creating, editing, and deleting a signature is only reachable through `signatureRoutes` (`worker/features/signatures/routes.ts:24-164`), which is mounted under the cookie-session web app, not `/api/v1`. An OAuth client with `mail:send` can read candidates and pick one, but the moment a user wants to fix a typo in their signature or add a new one, they have to leave the app and go find the web UI.

## Why that matters for a native client

Herald is an OAuth-only macOS mail client — it has no cookie session and no reason to ever open the server's web app for anything else (mailboxes, messages, drafts, send, labels are all `/api/v1`). Signature management is the one feature that forces a context switch back to the browser, which is a worse experience than just not having the feature: a user has to know the web app exists, find its URL, sign in there separately, and locate a settings page, all to edit two lines of HTML the API already understands how to render on send. For a client that otherwise never needs the web UI, this is the single remaining tether to it.

## Proposal

Mirror the existing internal routes almost verbatim under `/api/v1`, reusing the schemas and service functions as-is — the service layer (`createSignature`/`updateSignature`/`deleteSignature`/`listManageableSignatures` in `service.ts`) doesn't need to change, only the mounting and principal resolution:

```
GET    /api/v1/signatures/manage             -> Signature[]              (scope: ?)
POST   /api/v1/signatures                    -> Signature (201)          (scope: ?)
PATCH  /api/v1/signatures/{id}               -> Signature                (scope: ?)
DELETE /api/v1/signatures/{id}               -> 204                      (scope: ?)
```

(Route names are placeholders — happy to fold `manage` into the existing `GET /signatures` behind a query param, or keep it separate to avoid colliding with the `from`-scoped candidate list; whatever fits your naming conventions best.)

Bodies would be exactly `createSignatureSchema` / `updateSignatureSchema` (`validation.ts:17-30`): `{name, html, scope: {type: user|mailbox|domain, id}, isDefault}` for create, a partial of `{name, html, isDefault}` for update. Errors already exist and translate cleanly to API error codes: `SIGNATURE_INVALID` (400), `SIGNATURE_FORBIDDEN` (403), `SIGNATURE_NOT_FOUND` (404), `SIGNATURE_NAME_CONFLICT` (409, per-scope unique name).

**Inline images.** The internal routes already support up to 5 inline `<img>` per signature via `data:` URIs, sanitized and capped at 256 KB each (`content.ts:9-45`, `sanitizeSignatureContent`). If that surface is exposed on `/api/v1` too, the same `data:` URI approach in the JSON body is the simplest path — no new multipart endpoint needed, since the existing validation already parses and magic-byte-checks base64 image data inline. Whether the encoded size limit needs revisiting for a JSON-body API (vs. the web app's likely different upload path) is a question for you; I don't have visibility into how the web client currently gets images in.

## The scope question

`GET /signatures` (candidates) already uses `mail:send`, which is a reasonable default for management too — reusing it means no new consent screen for clients that already ask for send access, and semantically "can compose signed mail" and "can edit what gets appended" aren't obviously different permissions. On the other hand, editing signatures is a standing, destructive-ish account-configuration action (it touches shared mailbox/domain defaults, not just the caller's own mail), which is a different risk class than sending a message — a case for a narrower `signatures:write` (or `signatures:manage`) scope that a client only requests when the user actually opens signature settings, rather than bundling it into every send-capable OAuth grant. I don't have a strong preference; whichever fits how you think about scope granularity elsewhere (e.g. `mail:write` vs `mail:send` already split by risk, not by resource).

## Access-level mapping

The internal `requireManageScope` (`service.ts:227-245`) already encodes exactly the rule an `/api/v1` version would need to reuse unchanged:

- **`scope: user`** — only the signature's own `scope.id === actor.id`; no delegation.
- **`scope: mailbox`** — requires mailbox access level `"manager"` (`requireMailboxAccess(..., "manager")`), consistent with how mailbox-level settings are gated elsewhere in the API (stricter than the `"agent"` level that read/send need).
- **`scope: domain`** — requires the actor's account role to be `owner` or `admin`; any other role is `SIGNATURE_FORBIDDEN` regardless of mailbox access.

`isDefault` changes are audited as a distinct `signature.default.change` action alongside `signature.create`/`update`/`delete` (`routes.ts:38-53`, `89-97`, `135-143`) — worth preserving on an `/api/v1` mount for parity with the web app's audit trail.

## What Herald ships today

Herald currently only *reads* signatures (`GET /signatures?from=`) and lets the user pick automatic/selected/none per compose — it never renders or edits signature HTML. That's a deliberate scope cut given the current API surface, not a product decision; if management ships on `/api/v1` we'd add a settings screen for it.

Happy to help scope or implement this — spec first (`SignatureInput`/`Signature` schemas already exist informally in the internal routes, so it's mostly plumbing plus the scope decision above).
