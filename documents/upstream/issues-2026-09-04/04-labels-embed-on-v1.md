Title: Mail API: allow the `labels` embed on `/api/v1` behind `?includeLabels=true` — the code already exists, it's just gated off by path

Design proposal, offering to implement. Everything below is v1.3.4.

## What exists

Labels are fully available on `/api/v1` as a *filter* and as a *write*: `GET /api/v1/labels`, and `PUT`/`DELETE /{messages|conversations|drafts}/{id}/labels/{labelId}` are all mounted there (`worker/features/mail-api/routes.ts:16-21`, mounted at both base paths by `worker/routes/index.ts:91-92`). `GET /messages`, `/conversations` and `/drafts` all accept `labelId` and repeated `labelIds`. The assignment routes even return the authoritative post-write label set (`worker/features/messages/routes.ts:243-261`), which is what makes optimistic assignment reconcile cleanly — that part is genuinely nice to build against.

What v1 does not do is *embed* membership in message, conversation or change payloads. One predicate decides it:

```ts
function includeLabels(request: Request): boolean {
  return mailApiBasePath(request) !== "/api/v1";
}
```

(`worker/features/messages/routes.ts:325-326`, applied at `:73`, `:97`, `:115`, `:225`.) The same test is inlined for conversations (`worker/features/messages/conversation-routes.ts:61`) and for the change journal (`worker/features/messages/change-routes.ts:35`, which returns the page untouched on v1 and otherwise decorates every upsert via `labelsForMessageIds`, `:36-52`). The spec matches: `MessageSummary` has `labels` in `hqbase-mail-api-v2.openapi.json` and not in the v1 document.

The journal doesn't fill the gap either. A label write batches an assignment with `UPDATE messages SET updated_at = ?` (`worker/features/labels/queries.ts:218` for a message, `:305` for a thread), and `message_changes` is populated by an `AFTER UPDATE ON messages` trigger (`migrations/0013_message_changes.sql:19-20`), so the edit *does* produce a journal entry. But on v1 that entry is a bare message upsert with no label data — verified live against a local 1.3.4 instance: assigning a label produced a `messages` events frame and a `/changes` upsert whose `message` object had no `labels` key. The wake socket agrees by design: a label assignment calls `publishMessageMailEvent`, which publishes topic `"messages"` (`worker/features/events/service.ts:27-33`); the `labels` topic fires only for label CRUD. So neither the journal nor the socket can tell a client *which* label changed, or that a label changed at all rather than a read/star flip.

## Why it matters for a native client

With no embed and no delta, the only way to know membership on v1 is to enumerate it: `GET /labels`, then one `GET /messages?labelId=…` page-walk **per label**, on a timer, forever. That is Herald's single most expensive idle behaviour. We've already gated the cadence — 120s while labels are actually on screen, 750s when nothing visible shows them (`SyncEngine.defaultLabelPollInterval` / `defaultIdleLabelPollInterval`) — and it is still one full listing per label per pass on a client that otherwise runs on a cursor journal plus a wake socket and issues almost no idle traffic. It also can't be made correct cheaply: a walk that hits the page cap must be discarded rather than written, because the sweep result is authoritative by construction and a truncated listing would erase assignments the server simply hadn't returned yet.

"Just use `/api/v2`" isn't available to us. An OAuth token is bound to exactly one resource — `authenticateOAuthBearer` rejects unless `tokenResources.length === 1 && tokenResources[0] === options.resource` (`worker/auth/oauth-principal.ts:87-93`), and the resource is `origin + "/api/v1"` vs `origin + "/api/v2"` (`worker/auth/auth.ts`, `mailApiResource` / `mailApiV1Resource`; selected per request by `mailApiResourceForRequest`, `worker/auth/mail-api.ts:245-249`). A v1-consented token gets 401 on v2, so moving means re-consenting every account on every install — a forced sign-out for a feature-parity change, which is a worse user event than the polling it would fix.

## Proposal (recommended)

Enable the existing embed on v1 opt-in:

```
GET /api/v1/messages?includeLabels=true
GET /api/v1/messages/{id}?includeLabels=true      (and /thread)
GET /api/v1/conversations?includeLabels=true
GET /api/v1/changes?includeLabels=true
```

That is a change to `includeLabels()` alone — `mailApiBasePath(request) !== "/api/v1" || request query opts in` — and the decoration paths (`withMessageLabels`, `withConversationLabels`, `labelsForMessageIds`) are the same ones v2 already runs. Off by default, so every existing v1 client sees byte-identical responses; a client that opts in pays the same per-page label query v2 pays today. `/changes` would need `includeLabels` excluded from the `INVALID_CHANGE_FILTER` rejection list (`change-routes.ts:14-22`) — it isn't a filter, it doesn't change which rows are returned or the cursor ordering, so the "no filters on the journal" invariant is untouched.

For us this collapses the entire per-label sweep into the sync we already run: the journal upsert would carry membership, so label state would converge with the same latency as read/star state and the idle request rate would drop to zero extra requests.

## Alternatives, if the query parameter isn't the shape you want

- **Labels only in journal upserts**, not in list payloads — strictly smaller, and it's the half that actually removes the polling; list responses would still need one sweep at bootstrap.
- **A v1→v2 token migration path** (accept a v1-resource token on v2, or a resource-upgrade grant that doesn't require re-consent) — solves this and every future v1/v2 divergence at once, but it's real OAuth surface rather than a two-line predicate.
- **Leave v1 alone and document it** — if v1 is frozen on purpose, saying so plainly in the spec would at least let clients plan; we'd then be asking for the migration path instead.

## Open question

Was the v1 exclusion a compatibility decision (don't add fields to a shipped schema) or a versioning one (labels are a v2 feature)? If it's the former, an opt-in parameter answers it exactly — no unrequested field ever appears. If it's the latter, we'd rather discuss the migration path than argue for the embed.

Happy to implement: spec first, then the predicate plus tests asserting v1 default responses are unchanged and that `includeLabels=true` matches the v2 payload field-for-field.
