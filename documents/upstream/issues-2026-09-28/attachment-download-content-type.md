# Issue draft — OpenAPI: `GET /api/v1/attachments/{id}` declares only `application/octet-stream`

**Status:** draft, not filed. File on HQBase/hqbase after Alan's go; spec-first fix belongs in hqbase-site.

## Title
OpenAPI: attachment download declares `application/octet-stream`, but the server sends the stored Content-Type

## Body
`GET /api/v1/attachments/{id}` is documented with a single 200 response body of `application/octet-stream`. The server actually answers with the attachment's own stored Content-Type — e.g. `image/png` or `application/pdf` (draft uploads record the file part's Content-Type, per `POST /drafts/{id}/attachments`).

Generated clients that honour the spec reject the mismatch. swift-openapi-generator throws "unexpected content type" before reading the body, so in Herald every typed attachment failed to download or preview until we patched our vendored copy.

**Suggested fix (spec only, no server change):** declare the 200 body as any media type, matching the real behaviour:

```json
"200": { "description": "Attachment", "content": { "*/*": { "schema": { "type": "string", "contentEncoding": "binary" } } } }
```

Optionally note in the description that the response carries the attachment's stored Content-Type (falling back to `application/octet-stream` when none was recorded).

**Herald workaround:** `scripts/vendor-openapi.py` rewrite 4 (`ANY_CONTENT`) widens this route to `*/*`; commit 24b1871. Drop it once upstream's spec is fixed.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
