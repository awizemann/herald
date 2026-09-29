---
created: 2026-09-29
updated: 2026-09-29
source_sha: 2bfa6bee79e5baf669c80ee8cf23b74d74feaead
source_paths: Herald/Design
source_paths_inferred: false
---

# Design System

**MailTheme** is the single source of truth for colors, spacing, typography, and animations. No raw `Color`, padding, or font-size literals in UI code where a token exists.

## Token hierarchy

**Status colors** (MailTheme enums)
- `red` (error), `orange` (warning), `yellow`, `green` (success), `blue` (info), `gray`.
- Used for badges, message flags, error states.

**Account tints** (MailboxTint struct)
- Per-mailbox custom tint color; derived from the mailbox's icon color in HQBase.
- Applied to chips, selection highlights, mailbox avatars.

**Neutral surfaces** (MailTheme.Palette)
- `background`, `secondaryBackground`, `tertiaryBackground` — for layered surfaces.
- `foreground`, `secondaryForeground` — for text and icons.
- Respond to light/dark appearance automatically.

**Spacing** (MailTheme.Spacing)
- `small`, `medium`, `large`, `extraLarge` — padding, gaps, margins.
- 4pt, 8pt, 16pt, 24pt base scale.

**Radius** (MailTheme.Radius)
- `small`, `medium`, `large` — used for buttons, chips, popovers.

**Typography** (MailTheme.Typography)
- `body`, `caption`, `headline` — named fonts at standard sizes.
- Uses system fonts, responds to accessibility settings.

**Animation** (MailTheme.Animation)
- `.default` — 0.2s ease-in-out, for list reorders and transitions.
- `.quick` — 0.1s, for small UI touches.

## Reusable components

**AttachmentChip** — shows filename, size, and a trailing action (e.g., "×" to remove).
**LabelChip** — displays a label with its colored background (derived from HQBase's label color).
**LabelChipRow** — horizontal scrolling row of label chips.

## Rules

1. **No raw literals.** Every padding, color, font, radius, and animation should come from MailTheme.
2. **Accessibility first.** Use named colors (not hex), respond to `.colorSchemeContrast`, test with VoiceOver.
3. **Light + dark appearance.** All colors have light/dark variants; set once on MailTheme, views don't know which.

## When you touch this

- Adding a new chip component? Subclass LabelChip or AttachmentChip; reuse the styling logic.
- Changing a spacing scale (e.g., making `small` 3pt instead of 4pt)? Update MailTheme.Spacing and let the compiler find all usages.
- Adjusting animation speed? Edit MailTheme.Animation and test that it feels snappy on a real machine (Xcode preview is misleading).
