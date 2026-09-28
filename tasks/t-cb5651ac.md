---
id: t-cb5651ac
title: Redesign dogfooding follow-ups (review after Alan uses the new design)
status: ideas
added: 2026-09-27
---

## Description

Items where the redesign may have reduced functionality or left a design call open; Alan will judge after using it.

- Reading pane "To" chip shows the owning mailbox address, not the message's full recipient list (R6, matches the handoff mock). Recipients/CC no longer visible in the header.
- Labels no longer span folders (label ∩ folder, plan v2 N3): an archived labelled thread only shows under Archived.
- A label does not filter Drafts (Herald can't read labels on drafts); it stays set and reapplies on the next conversation folder (R3a).
- Draft rows show "Draft" as the sender and no longer show recipients on screen (R5, matches mock 5a-3; VoiceOver still reads them).
- Row senders show the From display name rather than the raw header (R5).
- Global "Notify me about new mail" is the master switch: a domain set to notify cannot override global off (R3b).
- No AccentColor asset: standard controls use the system accent, not the design accent (R1).
- Generated asset colour symbols (Color.ink etc.) let views bypass MailTheme — consider ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = NO (R1).
- Row separators left to the system list default; not verified that they hide next to the selection as designed (R5).

## Plan



## Artifacts



