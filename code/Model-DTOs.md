---
created: 2026-09-29
updated: 2026-09-29
source_sha: 2bfa6bee79e5baf669c80ee8cf23b74d74feaead
source_paths: HeraldKit/Sources/HeraldKit/Model
source_paths_inferred: false
---

# Model DTOs

All data that crosses the HeraldKit→Herald boundary (from sync engine to views) is Sendable, Codable, and immutable. These DTOs are **not** @Model classes; they're pure Swift structs that views can safely hold in @State and @Published.

## Core types

**ConversationSummary** (Sendable struct)
- `id: Conversation.ID`, `snippet: String`, `senderPreview: String`, `timestamp: Date`, `unreadCount: Int`.
- Derived from CachedConversation by the sync engine; views render this, never touch CachedConversation.

**ConversationPage** (Sendable struct)
- A paginated chunk of conversations: `items: [ConversationSummary]`, `cursor: String?`, `hasMore: Bool`.
- Returned by MailAPIClient.listConversations (for server-side paging) and MailViewModel (for filtered results).

**Draft**, **DraftSummary** (Sendable structs)
- `Draft` is the full composition state: `to`, `cc`, `bcc`, `subject`, `body`, `attachments: [DraftAttachment]`, `mode`, `signatureID`.
- `DraftSummary` is what the sidebar shows: `id`, `toPreview`, `subjectPreview`, `createdAt`.
- See [[herald-send-idempotency-and-send-holds]].

**MailEnums**
- `MailFolder` (.inbox, .archive, .trash, .sent, .drafts) — core folder constants.
- `ConversationFolder` — conversation's current folder (subset of MailFolder).
- `MessageDirection` (.incoming, .outgoing) — used for filtering and UI logic.
- All Sendable, Hashable, CaseIterable for easy switching.

## Invariant: Sendable DTO boundary

Never pass a CachedConversation or CachedMessage from HeraldKit to Herald's views. Always convert to the DTO (ConversationSummary, MessagePage, etc.) first. This:

1. Prevents views from accidentally mutating @Model data.
2. Decouples view code from SwiftData schema changes.
3. Keeps the DTO layer thin — views just consume immutable snapshots.

Conversion happens in MailViewModel and SyncEngine (e.g., `CachedConversation.toSummary()`).

## When you touch this

- Adding a new field to ConversationSummary? Likely needs a change to CachedConversation too. Update the sync engine's ChangeSet.apply() to populate it.
- Removing a field that views no longer use? Safe to remove from the DTO; the API might still send it, but Codable ignores unknown keys.
- Changing a field's type (e.g., snippet: String → snippet: AttributedString)? Update views that consume it and test Codable round-tripping.
