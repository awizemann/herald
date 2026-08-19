---
created: 2026-08-19
updated: 2026-08-19
source_sha: 35ba57be0606d427a5aa36e1500b7f685b444351
source_paths: Herald/Design, Herald/Views
source_paths_inferred: false
---

# UI and Design System

Herald's UI is built in SwiftUI with a single design system, `MailTheme`, that provides colors, spacing, and typography.

## MailTheme

`MailTheme` (`Herald/Design/MailTheme.swift:18`) is the single source of truth for design tokens:

- **Status colors** — Unread (accent), read, starred, flagged
- **Mailbox palette** — Colors assigned to each mailbox (Inbox → blue, Sent → green, etc.) via `MailboxColorAssignment` (`Herald/Design/MailboxColorAssignment.swift:10`)
- **Spacing** — `MailTheme.Spacing` (enum, line 170) with named sizes (xs, sm, md, lg)
- **Radius** — `MailTheme.Radius` (line 194) for corner radii
- **Typography** — `MailTheme.Typography` (line 205) for font scales
- **Animation** — `MailTheme.Animation` (line 217) for motion curves and durations

All new UI reads from these tokens; no raw `Color(hex:)`, `padding()` with literal numbers, or `font()` with `Font.system(size: ...)`.

## View components

- `ConversationListView` (`Herald/Views/ConversationListView.swift:45`) — The middle pane, showing conversations in a mailbox with search filtering.
- `ConversationRow` (`ConversationListView.swift:451`) — A single conversation row with subject, participants, date, and snippet.
- `ThreadMessageListView` (`ConversationListView.swift:239`) — Messages in the selected conversation, threaded.
- `DraftListView` (`Herald/Views/DraftListView.swift:12`) — A list of in-progress drafts.
- `ComposeView` (`Herald/Compose/ComposeWindow.swift:67`) — The compose window UI.

Views hold only transient UI state; app state lives in `MailViewModel` and `ComposeViewModel` (`@Observable`) and is read through the environment.

## Accessibility

Rows, chips, and controls carry VoiceOver labels; colors are never the only signal (the unread dot, star, and status chips have text or symbol equivalents); spacing and type come from the tokens so Dynamic Type and contrast stay consistent. The conventions note `.memory/conventions/Herald Design System and Accessibility.md` is the rule set new UI is reviewed against.

---
_Last updated: 2026-08-19 — UI and design system; fact-checked against the code for v0.3.0_