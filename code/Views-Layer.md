---
created: 2026-09-29
updated: 2026-09-29
source_sha: 2bfa6bee79e5baf669c80ee8cf23b74d74feaead
source_paths: Herald/Views
source_paths_inferred: false
---

# Views Layer

Herald's UI is a three-pane SwiftUI layout: sidebar (domains/mailboxes) → conversation list → message thread. All views are driven by `MailViewModel` (AppEnvironment's per-account view model) and never touch SwiftData @Model directly (Sendable DTO boundary).

## Key components

**ConversationListView** (struct: View)
- Renders the middle and right columns: a list of conversations filtered by the selected mailbox, plus the selected conversation's thread.
- `MiddleColumnView` — the conversation list with search and label filtering.
- `ThreadMessageListView` — the message thread when you select a conversation.
- `ConversationRow` — one row (sender, preview, date, unread dot).
- `ThreadMessageRow` — one message in the thread with headers and body.

**MailboxChip**, **LabelChip** (struct: View)
- Reusable display components for mailbox/label UI, styled with MailTheme tokens.

**DraftListView** (struct: View)
- Sidebar list of open drafts; clicking one opens the compose window.

**Focus keys** (MailCommands.swift)
- `MailModelFocusKey` — typed `FocusedValueKey<MailViewModel>` so the view hierarchy can access the current account's view model.
- `SelectedThreadIDKey` — which message is selected (drives keyboard navigation).

## Model-driven architecture

All views are driven by `MailViewModel` published properties:
- `conversations: [ConversationSummary]` — filtered, sorted list.
- `selectedConversationID: Conversation.ID?` — which row is highlighted.
- `selectedThreadID: Message.ID?` — which message in the thread.

When the view model updates (e.g., new mail arrives), `@Published` triggers re-render. Views never mutate data directly; they call view-model methods (e.g., `viewModel.markConversationAsRead(id)`), which dispatch to the API and wait for sync to reflect the change.

## Search and filtering

- Local instant filter: search text narrows the conversation list immediately.
- Server search: `viewModel.search(query:)` hits the API for full-text results.
- Label filter: `viewModel.selectLabel(id:)` narrows by label.
- See `SearchStatusBar` for the UI and `MailViewModel.search()` for the coordination.

## When you touch this

- Adding a new row action (e.g., snooze)? Add a method to MailViewModel, dispatch to OutboxService, test that the UI re-renders after sync.
- Changing the three-pane layout? Edit ConversationListView and test the focus key behavior (arrow keys, Tab).
- Fixing a slow render? Use Xcode's Core Animation tool (cmd+opt+A) to profile; most render delays are from un-optimized List rows.
