---
created: 2026-08-19
updated: 2026-08-19
source_sha: 35ba57be0606d427a5aa36e1500b7f685b444351
source_paths: HeraldKit/Sources/HeraldKit/Compose, Herald/Compose
source_paths_inferred: false
---

# Compose and Drafts

Herald lets you draft, edit, and send messages. Drafts are stored locally and synced to the server. Attachments can be dragged, dropped, or pasted.

## Draft lifecycle

A draft is a work-in-progress message. `ComposeDraft` (`HeraldKit/Sources/HeraldKit/Compose/ComposeDraft.swift:29`) represents it:

- **Local draft** — User starts composing; the draft is created locally via `ComposeDraft`.
- **Save to server** — `OutboxService` (`HeraldKit/Sources/HeraldKit/Compose/OutboxService.swift`) uploads the draft to HQBase.
- **Sync back** — The server returns a draft id; Herald stores it locally in `MailStore` as a `CachedDraft`.
- **Edit** — User makes changes; `ComposeViewModel` (`Herald/Compose/ComposeViewModel.swift:16`) manages the local state.
- **Send** — User clicks Send; `OutboxService` transmits the message to the server, deleting the draft.

`ComposeViewModel` autosaves to the server after a short debounce, so a crash mid-compose loses at most the last few seconds of typing; the saved draft reappears in the Drafts folder on relaunch. A draft with an open composer is protected from being overwritten or removed by a poll.

## Attachment handling

Attachments are managed via `AttachmentPasteboard` (`HeraldKit/Sources/HeraldKit/Compose/AttachmentPasteboard.swift:42`), which reads files and images from the macOS pasteboard.

`AttachmentLimits` (`HeraldKit/Sources/HeraldKit/Compose/AttachmentLimits.swift:13`) enforces size and count limits (per HQBase spec).

Attachments upload to the draft as they are added (chips show a spinner and a cancel control); Send waits for queued uploads to finish. Limits match the server exactly: 25 MiB per file, 25 MiB per draft, 20 files.

## Outbox service

`OutboxService` (`HeraldKit/Sources/HeraldKit/Compose/OutboxService.swift`) is an actor that:

- Queues outgoing messages
- Uploads attachments
- Transmits messages to the server
- Deletes drafts on success
- Reports errors and retries on transient failures

The app displays pending uploads and transmission errors in real-time.

---
_Last updated: 2026-08-19 — compose and drafts; fact-checked against the code for v0.3.0_