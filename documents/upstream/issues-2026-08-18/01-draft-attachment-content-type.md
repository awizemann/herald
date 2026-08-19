Title: Mail API: draft attachment uploads lose their MIME type because the spec declares no per-part Content-Type

The server already does the right thing — the spec doesn't let clients tell it.

**Server side (correct today).** `worker/features/drafts/routes.ts:44-49` reads the `file` part out of `formData()` and hands the `File` to `addDraftAttachment`, which stores `file.type || "application/octet-stream"` (`worker/features/drafts/queries.ts:180`, again at `:190`) and puts the object in R2 with that `httpMetadata.contentType`. So whatever per-part `Content-Type` the client sends is honored.

**Spec side (the gap).** `api/hqbase-mail-api-v1.openapi.json`, `POST /api/v1/drafts/{id}/attachments`, describes the body as:

```json
"multipart/form-data": {
  "schema": {
    "type": "object",
    "required": ["file"],
    "properties": { "file": { "type": "string", "contentEncoding": "binary" } }
  }
}
```

There is no `contentMediaType` and no `encoding` object. OpenAPI's default for a `string`/binary part with no encoding declared is `application/octet-stream`, and generators follow it: they emit a part with either no `Content-Type` header or a hardcoded `application/octet-stream`, with no parameter for the caller to pass the real type. Herald generates its client from the vendored spec and hits exactly this — the app knows the file is `image/png`, the generated request drops it, and every attachment lands in R2 and in `draft_attachments.content_type` as `application/octet-stream`. Recipients then get a PDF or an image that their mail client won't preview inline.

**Proposal.** Declare the part as caller-typed:

```json
"multipart/form-data": {
  "schema": {
    "type": "object",
    "required": ["file"],
    "properties": {
      "file": { "type": "string", "format": "binary", "contentMediaType": "application/octet-stream" }
    }
  },
  "encoding": { "file": { "contentType": "*/*" } }
}
```

`encoding.file.contentType: "*/*"` is the standard way to say "the client chooses"; generators then expose a content-type parameter on the operation instead of pinning octet-stream. No worker change is needed — `file.type` is already read — but it's worth a line in the operation description saying the server records the part's `Content-Type` and falls back to `application/octet-stream`, and an integration test asserting a part sent as `image/png` round-trips through `DraftAttachment.contentType` (today nothing pins that behavior).

While the operation is being touched, the documented limits are also worth adding to the description or to `DraftAttachment`: 25 MiB per file **and** 25 MiB per draft total → `413 ATTACHMENTS_TOO_LARGE` (`worker/features/drafts/queries.ts:167`), and at most 20 `attachmentIds` on send/reply (`worker/features/send/validation.ts:18`, `:44`). Clients currently discover those by hitting them.

Related: `/api/v1` still has no forward route, so a native client can't offer "forward with the original attachments" at all — filed separately.

Happy to PR this: spec first in hqbase-site, then the regenerated artifacts and the round-trip test.
