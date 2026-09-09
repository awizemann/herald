Title: Mail API spec: `Draft`'s `allOf` makes the `signature` key satisfy two incompatible schemas — generated clients can't decode any draft

Spec-only report, no server change proposed. Both documents (`api/hqbase-mail-api-v1.openapi.json`, `api/hqbase-mail-api-v2.openapi.json`) are affected identically at v1.3.4.

## What exists

`Draft` is composed out of the write schema:

```json
"Draft": { "allOf": [
  { "$ref": "#/components/schemas/DraftInput" },
  { "type": "object",
    "required": ["id","version","updatedAt","attachments","signature","labels"],
    "properties": { "…": "…", "signature": { "$ref": "#/components/schemas/SignatureSnapshot" } } }
]}
```

and `DraftInput` itself carries a `signature`, but the *selection* one:

```json
"DraftInput": { "properties": { "…": "…", "signature": { "$ref": "#/components/schemas/SignatureSelection" } } }

"SignatureSelection": { "oneOf": [
  { "required": ["mode"],      "properties": { "mode": { "const": "automatic" } } },
  { "required": ["mode","id"], "properties": { "mode": { "const": "selected" },
                                               "id": { "type": "string", "minLength": 1, "maxLength": 100 } } },
  { "required": ["mode"],      "properties": { "mode": { "const": "none" } } }
]}

"SignatureSnapshot": { "required": ["mode","id","name","html","text"],
  "properties": { "mode": { "enum": ["automatic","selected","none"] },
                  "id": { "type": ["string","null"] }, "name": {}, "html": {}, "text": {} } }
```

(`components.schemas.Draft` / `.DraftInput` / `.SignatureSelection` / `.SignatureSnapshot` in both documents.)

## What's missing

`allOf` is intersection, not override. A response object therefore has to validate its single `signature` key against **both** `SignatureSelection` and `SignatureSnapshot` at once. The server only ever emits the snapshot — `mapDraftRow` builds `{mode, id, name, html, text}` straight from the row columns (`worker/features/drafts/queries.ts:75-103`) — so the two halves disagree in practice, and code generators that model `allOf` as "decode every member and merge" (swift-openapi-generator, openapi-typescript-codegen, several others) fail the *selection* branch on every fetch.

The disagreement is not theoretical, because a snapshot can carry `"id": null`. `drafts.signature_id` is `REFERENCES email_signatures(id) ON DELETE SET NULL` (`migrations/0021_email_signatures.sql:51-52`), and `signature_mode` is a separate column with its own default (`:48-49`), so deleting a signature leaves a draft at mode `selected` with a null id until the next save re-resolves it. That value matches **no** `SignatureSelection` case: the `selected` branch requires a non-null `id` with `minLength: 1`, and the `automatic`/`none` branches are excluded by `mode`.

Minimal failing payload — a valid `GET /api/v1/drafts/{id}` body that a spec-faithful client rejects:

```json
{
  "id": "drf_1", "version": 3, "updatedAt": "2026-09-04T10:00:00.000Z",
  "mailboxId": null, "replyToMessageId": null, "forwardOfMessageId": null,
  "from": "owner@example.test", "to": ["a@example.test"], "cc": [], "bcc": [],
  "subject": "hello", "text": "body", "html": "", "attachments": [], "labels": [],
  "signature": { "mode": "selected", "id": null, "name": "", "html": "", "text": "" }
}
```

Even with a non-null id the merge is wrong (`name`/`html`/`text` are additional properties from the selection's point of view, and strict generators pin the union arm by `mode`); with a null id it is unambiguously unsatisfiable. The practical effect is that *every* draft fetch and every `GET /drafts` page fails to decode, not just drafts whose signature was deleted, because the generated model is emitted once for the whole schema.

## Why it matters for a native client

Herald generates its whole HTTP layer from the vendored spec, so a schema that can't be modelled isn't a decode warning — it's a build-time or first-request failure across drafts, `GET /drafts/changes`, and draft-backed compose. We patch our vendored copy rather than hand-write the client: `Draft` becomes `allOf[DraftFields, {…, signature: SignatureSnapshot}]`, where `DraftFields` is `DraftInput` **minus** the write-only `signature` key. Nothing else changes, and the patch has to be re-applied by hand after every spec regen, which is exactly the kind of drift that eventually ships a bug.

## Minimal proposal

Split the shared half, so the write schema keeps the selection and the read schema keeps the snapshot:

- add `DraftFields` = today's `DraftInput` without `signature`;
- `DraftInput` = `allOf[DraftFields, { properties: { signature: SignatureSelection } }]` (unchanged on the wire);
- `Draft` = `allOf[DraftFields, { …, signature: SignatureSnapshot, labels: … }]`.

That is byte-identical for every existing request and response; it only stops one key from being described twice. Worth documenting alongside it that `SignatureSnapshot.id` is null for a deleted signature and that the server degrades that to `automatic` on the next save — right now a client has to learn that from the migration.

Second, much smaller: the documents mix both OpenAPI 3.1 nullable spellings. Nineteen properties use `anyOf: [X, {"type": "null"}]` (`MessageSummary.mailboxId`, `DraftInput.mailboxId`, `MessageChangeDelete.mailboxId`, …) while exactly two use the type-array form — `SignatureSnapshot.id` and `SignatureCandidates.automaticSignatureId` (`{"type": ["string","null"]}`). Both are legal 3.1 and most tooling handles each, but they are not equivalent to every generator, and a vendoring script that normalises one form silently misses the other (ours did). Picking one spelling across the document is a no-op for the server.

## Open question

Is `Draft.labels` on `/api/v1` deliberate? It is declared and required in both documents, and the server matches — `mapDraftRow` attaches labels with no version gate (`worker/features/drafts/queries.ts:68-73`, `:102`) — whereas messages and conversations deliberately omit the embed on v1 (`worker/features/messages/routes.ts:325-326`). So drafts are the one v1 payload that does carry label membership. We rely on that today; we'd just like to know it's intended and not an oversight that a later release "fixes" by gating it.

Happy to open the spec PR for the `DraftFields` split (and the nullable-spelling sweep, if you want them together) — it's mechanical, and we've already been running the result.
