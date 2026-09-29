---
created: 2026-09-29
updated: 2026-09-29
source_sha: 2bfa6bee79e5baf669c80ee8cf23b74d74feaead
source_paths: HeraldKit/Sources/HeraldKit/Compose, Herald/Compose
source_paths_inferred: false
---

# Compose and Drafts

Composition in Herald spans two targets: **HeraldKit/Compose** (draft state, validation, send holds) and **Herald/Compose** (UI and view model).

## HeraldKit layer

**ComposeDraft** (Sendable struct)
- `id: UUID`, `mode: ComposeMode` (new/reply/replyAll/forward), `from`, `to`, `cc`, `bcc`, `subject`, `body`, `attachments`, `selectedSignatureID`.
- Immutable; changes create a new struct (views hold it in @State).
- See [[herald-signature-handling]] — Herald sends the signature *selection* on every send, never concatenates text.

**SendHold** (enum, String, CaseIterable)
- Reasons to prevent sending: `.noRecipients`, `.largeAttachmentConfirmation`, `.quotedHtmlCheck`, etc.
- `OutboxService.validateForSend(draft:)` returns a Set<SendHold> so the UI can show a confirmation sheet.

**OutboxService** (protocol `Outboxing`)
- Takes a validated draft, rotates the send key (see [[herald-send-idempotency-and-send-holds]]), posts to the API, and updates SwiftData on success.
- Idempotent: if the network fails mid-send, retrying with the same send key is safe (server dedupes).

**AttachmentPasteboard** (enum)
- Detects images and files on the pasteboard (`PasteboardContents.read()`) and converts to `PastedAttachment` (image data + MIME type).
- Used by ComposeViewModel when the user pastes.

## Herald layer

**ComposeViewModel** (final class, @MainActor)
- Holds the draft in @Published properties: `draft`, `sendHolds`, `attachmentUploadProgress`.
- Methods: `updateRecipient()`, `updateSubject()`, `addAttachment()`, `send()`, etc.
- Coordinates with HeraldKit's ComposeDraft and OutboxService.
- Handles attachment uploads (streaming progress to the UI).

**ComposeView** (struct: View)
- The compose window UI: recipient fields, subject, body editor, signature picker, attachment list.
- Buttons for Send, Save Draft, Discard.
- Checks SendHolds and shows confirmation sheets before sending.

**ComposePresenter** (ViewModifier)
- Handles opening and closing the compose window from any view (`view.compose(mode:draft:)`).

## Attachment flow

1. User drags a file or pastes an image → AttachmentPasteboard.read() → returns PastedAttachment (data + MIME type).
2. ComposeViewModel.addAttachment() → stores in the draft, starts upload in background.
3. Upload progress streams to MailViewModel.attachmentProgress → UI updates progress bar.
4. On send, all attachments are already uploaded; draft just references their server IDs.

## When you touch this

- Adding a send hold (e.g., "suspicious recipients")? Add a case to SendHold, check it in OutboxService.validateForSend(), and add a confirmation sheet in ComposeView.
- Changing signature handling? Update ComposeDraft's selectedSignatureID field and see [[herald-signature-handling]] for the API contract.
- Debugging a stalled upload? Check ComposeViewModel.attachmentUploadProgress and HQBaseAPIClient.uploadAttachment() error logs.
