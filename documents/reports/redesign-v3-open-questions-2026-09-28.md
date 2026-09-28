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

### V6 (compose window, 2df748a)
18. **Per-field red hint text removed** — problems now show once in the footer (and stay as VoiceOver hints). Rec: keep.
19. **Send is disabled (not just dimmed) with no valid recipient.** Rec: keep.
20. **Token field uses a window-level key monitor** for comma/semicolon/Delete because SwiftUI's TextField can't do it; works, but it's a workaround to remember. Rec: keep; revisit if Apple fixes `.onKeyPress(.delete)`.
- Not verified live: window drag, signature footer (no fake signatures), multi-domain From grouping and "Can't send" rows, dark mode, the real 820×620 size. Labels sit ~2pt below token text (minor polish).
- Heads-up: `./scripts/build-detached.sh` relaunches Herald on your REAL account (no fake flag). A blank New Message opened briefly during V6; nothing was sent or saved.

## Final state (V7, 2026-09-28)
Commits on main (not pushed): db538bd V1 · d6398d1 V2 · f6c2d65 V3 · 984286b V4 · bd1e15a V5 · 2df748a V6 · 86a5623 review fixes (9) · 2ab8b0c Save Draft with invalid address no longer loses the message · a1cface paste-resync scoped to its field.
Tests: 651 app + 470 HeraldKit pass; 12 UI tests pass (as of 86a5623).
Design v1/v2 folders deleted (design/ tier left dirty for you to commit via Memophant).
Not covered by automated tests (check by hand): Download All double-click guard, menu Paste resync, Tab committing a typed address.
Suggested review launch: Debug build with `-HeraldUITest twoAccounts -HeraldFakeAttachments YES`, plus your real account for dark mode, signatures, multi-domain From and threads.

## Alan's answers (2026-09-28)
- Q1 → Use the app fonts (Geist / Source Serif / Geist Mono via MailTheme.Typography) everywhere; replace system text styles. QUEUED.
- Q2 → Remove `UsageEvent.mailboxColorChanged`; audit account switching and domain switching for analytics events and add them if missing. QUEUED.
- Q3 → `info.circle` for Domain Overview is fine. CLOSED.
- Q4 → Leave monogram override clash as is. CLOSED.
- Extra feedback: New button overflowed toolbar + should use account colour → DONE 41730b5. Signature toggle "this scope" → names domain/mailbox/personal → DONE 41730b5. Per-domain colour override in Settings › Domain › Overview → IN PROGRESS.
- Q5 → Keep toolbar title + folder subtitle. Title follows the scope: All domains = account, inside a domain = the domain, inside a mailbox = the mailbox address. QUEUED.
- Q6 → Native folder menu is fine. CLOSED.
- Q7 → Leave Compact `me@` prefix. CLOSED.
- Q8 → Search must also work in Drafts (field stays; drafts filtered). QUEUED.
- Q9 → App sign-out copy is right; spec README corrected. CLOSED.
- Q10 → Sync caption fine; spec README corrected. CLOSED.
- Q11 → Leave minor deviations. CLOSED.
- Fonts + analytics (Q1/Q2) → DONE 9574175 (app fonts + guard test), a78106a (removed mailboxColorChanged; new scope_changed event — add to the analytics backend's allow-list if it has one).
- Q12/Q13 → Quick Look throws an error. Cache attachments in Application Support; Quick Look from there; Download = save panel defaulting to ~/Downloads. IN PROGRESS.
- Q15 → Add a per-domain "Default From address" (Settings › Domain › Overview). Composing inside a domain (or its mailboxes' fallback) uses it; a domain with only one sendable address auto-selects it. QUEUED.
- Q16 → Keep hidden domains in the From picker (fix coming upstream). CLOSED.
- Q17 → Replies (reply / reply-all) are locked to the address the original was sent to — From picker not changeable on replies, for now. Forwards keep the picker. QUEUED.
- Q18, Q19, Q20 → Keep (Alan will keep testing the token field). CLOSED.
- Q14 (card max width 320) → not answered yet; kept as built.
- Q12/Q13 → DONE eb4725b: root cause = temp-dir cache wiped by any other Herald process (test runs); cache now in Application Support; Download defaults to ~/Downloads.
- Q15/Q17 → DONE 1d3c88c: per-domain Default From (auto when one address), replies locked. Also Drafts search clears a hidden selection.
- Q5/Q8 → DONE 7035392.
All questions answered except Q14 (attachment card max width 320 — kept).
