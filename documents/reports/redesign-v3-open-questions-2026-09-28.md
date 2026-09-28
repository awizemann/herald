# Redesign v3 — open questions for Alan (review at end of run)

Plan: `documents/plans/herald-redesign-v3-audit-and-compose-2026-09-28.md`. Each item was left UNCHANGED pending your answer. "Rec" = orchestrator recommendation.

## From V1 (tokens & identity, db538bd)
1. **System fonts** — SignatureSettingsView, OnboardingView, RootView banners still use macOS system text styles instead of bundled Geist/Source Serif (compose is rebuilt in V6). Move them? Rec: yes, small visual pass.
2. **Dead analytics event** — `UsageEvent.mailboxColorChanged` (Herald/Analytics/UsageEvent.swift:299) is never sent since mailbox colours were removed. Remove? Rec: yes.
3. **Domain Overview icon** — Settings sidebar uses `info.circle`; spec lists none. Keep? Rec: keep.
4. **Monogram override clash** — a hand-set monogram can equal another domain's automatic letters ("AC" next to acme.co); the 3-letter clash rule doesn't apply to overrides. Leave? Rec: leave (user chose it).

## From V2 (main window, d6398d1)
5. **Toolbar title/subtitle** shown above the list; mocks show none. Kept so the Window menu names the window. Hide visually? Rec: hide the visible title, keep it for the Window menu.
6. **Folder menu** — native menu ~150pt, no folder icons; spec 224pt with icon column. Needs a custom popover. Worth it? Rec: no, native menu is fine.
7. **Compact rows** show the `me@` mailbox prefix; the Settings Compact preview (5b-2) shows only badge + sender. Which is right? Rec: make the preview match the real rows.
8. **Search field** sits at far right of the toolbar (standard macOS) and disappears in Drafts, shifting the toolbar. Rec: leave.

## From V3 (settings, f6c2d65)
9. **Sign-out copy** — spec "Nothing changes on the server" is untrue (sign-out revokes the sign-in grant on the server). App says "Your mail on the server isn't touched." Rec: keep app wording; correct the spec.
10. **Sync caption** omits "checks every 2 minutes" because sync is driven by server signals, not a fixed timer. Rec: keep.
11. **Minor deviations** — sidebar icons in blue accent (mock grey); swatches ~10pt apart (spec 6) to keep 28pt click areas; native segmented density control (mock custom pill); Compact preview padding 8 vs 7. Rec: leave all.

## Not verifiable live (fake-server mode; local instance is http-only, Herald needs https)
- Dark mode, focused (blue) sidebar selection, thread view, "No mailbox" drafts, labels, hidden-domains list with entries, domain Signatures with real data. You'll want to eyeball these when you review.

## From V4+ (appended as phases finish)

### V4 (attachment cards, 984286b)
12. **Compose attachments are copied locally** (instead of holding file access open all session) so Quick Look/Download work; costs disk equal to the attachments, deleted on remove and on window close. Rec: keep.
13. **Single Download keeps the save panel**; spec says save straight to ~/Downloads. Rec: keep the save panel (you choose where), or switch to ~/Downloads — your call.
14. **Card max width 320** (spec gives none) so one long name can't fill a row. Rec: keep.
- Not verified live: Download All (folder panel couldn't be scripted — unit-tested only), compose cards, dark mode. Debug flag `-HeraldFakeAttachments YES` gives fake messages attachments for review.

### V5 (compose model, bd1e15a)
15. **"Account primary" address** — the server has no account-level primary, so Herald uses the first visible mailbox's primary sendable address (sidebar order). Rec: keep; or add a Settings choice later.
16. **Hidden domains in the From picker** — listed (you can still send from them), but never picked as a default. Rec: keep.
17. **Replying from a different mailbox** — picking a From in another mailbox during a reply moves the draft to that mailbox. Unverified whether HQBase accepts a reply sent from a different mailbox. Rec: test once on your instance; add to the upstream question list if it fails.
- Behaviour change: a reply now goes out from the address the message was sent to (e.g. support@), not the mailbox's primary.
