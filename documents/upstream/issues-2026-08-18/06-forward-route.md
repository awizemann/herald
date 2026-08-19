Title: Mail API: expose forward on `/api/v1` — the implementation exists but only MCP can reach it

The forward path is already written, tested, and reachable from the MCP tools; `/api/v1` just has no route for it.

**What exists.** `forwardMessageSchema` (`worker/features/send/validation.ts:54-77`) with `messageId`, `from`, `to`/`cc`/`bcc`, optional `subject`, `text`, `html`, `attachmentIds`, and `includeOriginalAttachments` (default `true`); `forwardMessage` (`worker/features/send/forward.ts:14`), which re-attaches the original's attachments when that flag is set (`:33`), stamps `forwardOfMessageId` (`:48`) and builds the quoted body via `forwardedBody` (`:95`); unit coverage in `test/unit/worker/features/send/forward-service.test.ts`. It's wired into `worker/features/mcp/send-tools.ts`.

**What's missing.** `worker/features/send/routes.ts` mounts only `POST /send` and `POST /reply`, and the spec has only `/api/v1/send` and `/api/v1/reply`. So an OAuth client with `mail:send` cannot forward.

**Why that matters for a native client.** The workaround is to compose a draft with `forwardOfMessageId` and send it via `POST /send` — except `sendMessageSchema` (`validation.ts:9-20`) has no `forwardOfMessageId` field, so the linkage is lost, and more importantly there is no way to carry the original's attachments: `attachmentIds` on send/reply must be *draft* attachment ids (`requireDraftAttachmentIdsAccess` in `worker/features/send/routes.ts:38`), and the original message's attachments aren't draft attachments. A client would have to download each original attachment and re-upload it as a draft attachment — round-tripping potentially 25 MiB through the user's connection to produce bytes the server already has in R2 — and even then it can't reproduce `includeOriginalAttachments` semantics. Herald currently offers forward-without-original-attachments and reconstructs the quoted body client-side, which is both worse and inconsistent with how `/reply` composes server-side (`reply-body.ts`).

**Proposal.** Add `POST /api/v1/send/forward` (or `/api/v1/forward`, whichever fits your route naming) with `mail:send`, the existing `forwardMessageSchema` as the body, the same `enforceRateLimit` scope and `recordAudit` treatment as `/send`, the mailbox-access check on the original message (`getMessageMailboxId` + `requireMailboxAccess(…, "agent")`, as `/reply` does) and on the sending mailbox, plus `requireDraftIdAccess`/`requireDraftAttachmentIdsAccess` if you want a `draftId` on it for symmetry with send/reply. Response is the same shape as `/send` (201). Spec gets a `ForwardInput` schema next to `SendInput`/`ReplyInput`.

That's roughly 25 lines of route plus the spec entry — the service layer is untouched.

Related: draft attachment uploads currently lose their MIME type because the spec declares no per-part Content-Type — filed separately.

Happy to PR it: hqbase-site spec first, then the route, regenerated artifacts, and an integration test that a forward with `includeOriginalAttachments: true` carries the original's attachments and sets `forwardOfMessageId`.
