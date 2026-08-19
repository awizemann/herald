Title: Mail API: a streaming `GET /api/v1/changes/stream` (SSE or long-poll) so native clients don't have to poll

Design proposal, offering to implement. Follow-on to the changes feed from #37.

## Where things stand

`GET /api/v1/changes` (`worker/features/messages/change-routes.ts:12`, `change-queries.ts:36`) gives a durable, cursor-ordered journal backed by the `message_changes` table and its three triggers (`migrations/0013_message_changes.sql`). It's exactly the right primitive and it made delta sync possible for us — thank you.

What's missing is a *notification* edge. `GET /changes` still has to be polled, so a client's new-mail latency equals its poll interval, and the only push mechanism in the product is browser Web Push over VAPID (`worker/features/notifications/routes.ts`, `delivery.ts`), which a native app can't consume: a macOS/iOS app needs APNs, and APNs needs an Apple developer team and per-app certificates that a self-hosted HQBase instance has no business owning. So the practical choice for third-party native clients today is "poll fast and waste requests" or "poll slowly and be late". Herald currently polls; every user gets either a battery cost or minute-scale mail latency, and the Dock badge and notification-on-new-mail feel wrong at either setting.

## Proposal

Add one route that carries no new data model — it's purely a wake-up over the journal that already exists.

```
GET /api/v1/changes/stream?cursor=<opaque>   scope: mail:read
Accept: text/event-stream
```

Behavior:

- **Cursor is required.** Unlike `/changes`, there's no checkpoint mode; a client checkpoints with `GET /changes` (no cursor) and then streams. Same `INVALID_CHANGE_CURSOR` / `CHANGE_CURSOR_EXPIRED` codes, same rejection of `mailboxId`/`folder`/`search` filters (`change-routes.ts:14-22`).
- **On connect,** drain: emit `MessageChangePage` payloads from the given cursor until `hasMore: false`, so a client that reconnects after a gap never misses anything and never needs a second endpoint.
- **Then idle,** emitting a `event: keepalive` comment every ~25 s and a `data:` frame whenever new journal rows appear for the caller's accessible mailboxes.
- **Frames are the existing schema.** `event: changes` with a `MessageChangePage` body — same `changes[]`, `nextCursor`, `hasMore`. Clients reuse the generated types and the same apply path they already have. SSE's native `Last-Event-ID` maps onto the cursor for free.
- **Bounded lifetime.** Close after N minutes (5–10) with a final frame carrying `nextCursor`; the client reconnects with it. That keeps a Worker's connection budget predictable and makes the "stream is just an accelerated poll" invariant explicit.

## The Cloudflare-shaped question

On Workers, the honest options for "wake up when the DB changes" are:

1. **Long-poll instead of SSE.** `GET /changes?wait=30` — same route, same response, but if there are no changes the request parks for up to N seconds before returning an empty page. Internally that's still a sleep-and-recheck loop against `message_changes`, but it's ~15 lines, needs no Durable Object, degrades to today's behavior with `wait=0`, and cuts new-mail latency to seconds. Any HTTP client can use it. **This is the option I'd start with.**
2. **SSE fed by a Durable Object** that the ingress path (`worker/email/store-email.ts`) notifies after storing a message, so idle streams cost nothing and wake immediately. Strictly better latency and cost, but it's a new stateful component, a new binding in generated Wrangler config, and a migration story for existing installs.
3. **SSE with server-side polling of the journal** — the shape above, but the Worker re-queries `message_changes` on a timer while holding the connection. Nicer client contract than (1) with none of (2)'s infrastructure, at the cost of a held connection per client.

I'd propose landing (1) first as a `wait` parameter on the existing `/changes` route — small, additive, spec-only change with no new component — and treating `/changes/stream` as a later step if you want true SSE. If you'd rather go straight to (2) or (3), I'm happy to build that instead; I mostly want to avoid guessing which trade-off fits how you run instances.

Either way the client contract stays "the journal is the truth, this only tells you when to read it", so a client that ignores the stream entirely still converges.

Happy to implement, spec in hqbase-site first. What's your preference on the three?
