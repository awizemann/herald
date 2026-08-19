Title: Mail API: drafts have no delta path (not in the changes journal, `GET /drafts` unpaged), and the `drafts` message folder is dead

Three related gaps that together make a Drafts folder hard to build in a native client.

## 1. Drafts aren't in the changes journal

`migrations/0013_message_changes.sql` puts triggers on `messages` only, and `listMessageChanges` (`worker/features/messages/change-queries.ts:36`) reads `message_changes` joined to messages. Drafts live in their own `drafts` / `draft_attachments` tables (`worker/features/drafts/queries.ts`), so nothing a user does to a draft — on the web app, on another device, or via the MCP tools — ever reaches `GET /api/v1/changes`. A client that has adopted checkpoint + changes as its sync loop (as Herald has, after #37) has no incremental signal for drafts at all.

## 2. `GET /drafts` is a bare unbounded list

```ts
export async function listDrafts(db: D1Database, userId: string): Promise<Draft[]> {
  const rows = await db
    .prepare("SELECT * FROM drafts WHERE user_id = ? ORDER BY updated_at DESC")
```
— `worker/features/drafts/queries.ts:71-77`, surfaced by `listAccessibleDrafts` (`worker/features/drafts/access.ts:14`) and `draftRoutes.get("/")` (`worker/features/drafts/routes.ts:12`). No `limit`, no `cursor`, no `updatedSince`, and each row fans out into a per-draft `SELECT … FROM draft_attachments` (`queries.ts:45-49`) plus a per-draft access check. So the only way for a client to notice a draft changed is to re-fetch every draft with all of its attachment rows and diff — N+1 queries per poll, over the whole set, forever.

`drafts.updated_at` already exists, is already the sort key, and is already the optimistic-concurrency stamp (`version` / 409 `DRAFT_CONFLICT`) — the delta key is sitting right there.

## 3. `drafts` in the message folder enum is unreachable

`messageFolders` includes `"drafts"` (`worker/features/messages/types.ts:1`), the `messages.folder` CHECK constraint allows it (`migrations/0001_initial.sql:91`), and the spec advertises it in the `folder` enum of `GET /api/v1/messages`. But nothing ever writes it: inbound sets `inbox` or `catchall` (`worker/email/inbound-plan.ts:19`), sending sets `sent` (`worker/features/send/service.ts:173`), and the actions only move messages to `archived`/`trash`. Drafts are a separate table. So `GET /api/v1/messages?folder=drafts` is a documented parameter value that returns `[]` by construction — a client author reads the spec, builds their Drafts folder on it, and ships something permanently empty. (The conversation enum correctly omits it and has `starred` instead; the asymmetry is undocumented too.)

## Proposal

Smallest useful version, in order of value:

1. **`updatedSince` (or a cursor) on `GET /drafts`,** plus `limit`. `?updatedSince=<ISO8601>` filtered on `drafts.updated_at` with the same keyset shape as `/messages` (`updated_at DESC, id DESC`, opaque cursor, `Link: rel="next"`) would be consistent with #35 and would let a client poll a nearly-always-empty page. Deletions still need handling — either a `deletedDrafts: string[]` alongside, or a soft-delete `deleted_at` column, or the client tolerates "a draft id that 404s is gone" (workable, given a client already knows the full set from its first sync).
2. **Or: extend the journal to drafts** — a `draft_changes` table with the same trigger trio and a `GET /api/v1/changes/drafts` (or a `type: "draft-upsert" | "draft-delete"` variant in the existing feed, if you'd rather have one stream; that would be a breaking change to `MessageChange` consumers, so probably a sibling route). More work, but it makes drafts a first-class citizen of the sync model and gets deletes right by construction.
3. **Fix the enum either way:** either remove `drafts` from the `/messages` `folder` enum in the spec (and note it's retained in the DB CHECK for historical rows), or document it as always-empty and point readers at `/api/v1/drafts`. Same edit should document why the conversation enum differs.
4. While in there, the N+1 in `listDrafts` is easy to collapse into one `IN (…)` query over `draft_attachments` keyed by the page's draft ids.

Motivation: Herald is building a Drafts folder in the sidebar. Today the only implementation available is "call `GET /drafts` on a timer and diff the whole list", which is why the folder is currently hidden. (1) alone would make it a normal, cheap part of the sync loop.

Happy to PR any of these — my instinct is (1) + (3) as one small change and (2) as a follow-up if you want drafts in the journal proper. Which shape do you prefer?
