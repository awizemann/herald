# Herald redesign — grounding + implementation plan (2026-09-27)

Source: `design/design_handoff_herald_redesign/` (README + 4 `.dc.html` + screenshots).
Status: PLAN ONLY — nothing implemented. Open decisions in §2 must be settled before Phase 2.

## 1. What the code says (grounding)

| Design assumption | Reality in code/API | Consequence |
|---|---|---|
| Domains exist as a level | No `/domains` endpoint. `MailboxAddress.mailDomainID` exists, and the OpenAPI pins `Mailbox.addresses` to **exactly one** item (`minItems 1, maxItems 1`) | Every mailbox belongs to exactly one domain. Domain list, name (part after `@`), mailbox count and unread totals are all **derivable client-side** — no endpoint needed for navigation or the Overview/Mailboxes pages. `SignatureSettingsModel.domainName(of:)` already does this. |
| Domain scope for the list | `MailStore.conversations/unreadCount/hasConversation/messages` take `mailboxID: String?` (nil = all). Sync is per mailbox (`SyncEngine.syncMailbox`) | Domain scope = a **set of mailbox ids**. Store predicates change from `String?` to a set (`ids.contains($0.mailboxKey)`); sync untouched. |
| Per-domain unread | `unreadCounts: [FolderSelection: Int]` already computed per (mailbox, folder) | Domain counts = sum of its mailboxes' counts. No new store queries. |
| Server search scoped to domain | `GET /conversations` takes one `mailboxId` | Domain search = all-mailbox server search, filtered client-side to the domain's mailbox ids. |
| Delete domain | Nothing in v1. The spec's own `info.description`: "Administrative APIs are not part of this contract" | A server delete is not "missing an endpoint" — it is outside the API's stated scope. See decision D4. |
| Domain signatures | `/api/v1/signatures/manage` scope `domain` — already built (`SignatureManagementService`, `SignatureSettingsModel`) | Reuse, filtered to one domain. |
| Workflows | No API | Disabled row only, as designed. |
| Per-mailbox colours | `MailTheme.mailboxPalette`, `MailboxColorAssignment`, `MailboxSettingsPane`, `mailboxColorOverrides` in `MailViewModel` | Removed; replaced by per-account tints. Stored `mailboxColor.*` keys become dead (clean up once). |
| Labels | `MailLabel` has no mailbox — workspace-wide | See D2: design shows labels only at the mailbox level. |
| Drafts | `DraftSummary.mailboxID` is **optional** | Drafts with no mailbox would disappear from a mailbox-level Drafts list. See D1. |
| Settings window | `TabView` of 4 panes, 640×420 | Full rebuild to a split view. SwiftUI's `openSettings` has no route argument, so "Domain Settings…" from the main window needs a shared route in `AppEnvironment`. |
| Dock badge / notifications | Badge = sum of each account's all-mailbox inbox unread (`applyDockBadge`); notifier filter `NewMailNotifier.isNotifiable` has no mailbox/domain input | Per-domain `countInBadge` / `notify` / `hidden` need a mailbox→domain lookup passed into both. |
| Thread order | Already newest-first (owner decision 2026-08-16) | Matches design; only "Message N of M" and header are new. |
| Tokens | `MailTheme` has status colours, a 1-step radius scale, no colour tokens, system fonts | Big but mechanical expansion. Standards divergence ("MailTheme is the token source") holds. |

## 2. Decisions needed (my recommendation first)

- **D1 — Folders only at the mailbox level (functional regression).** In the design, "All domains" and a domain show **Inbox only**; Starred/Sent/Drafts/Archived/Trash appear only after drilling into one mailbox. Today you can open Sent/Starred/Trash across all mailboxes in one click. With 20 domains × many mailboxes, "what did I star?" becomes impossible.
  *Recommend:* keep the folder available at every level — a folder menu in the list header band ("Inbox ▾") at levels 1–2, the sidebar folder list at level 3. Scope and folder stay independent axes, which is also what the store already models.
- **D2 — Labels only at the mailbox level.** Labels are workspace-wide; showing them only under one mailbox implies they belong to it and hides them 2 levels deep. *Recommend:* labels section at level 1 (under Domains), listing filtered to the current scope.
- **D3 — Custom fonts (Source Serif 4, Geist, Geist Mono).** Fine licence-wise (OFL). Cost: loses SF's optical sizing and the native look; adds font registration. *Recommend:* adopt, but only through `MailTheme.Typography` tokens using `Font.custom(_:size:relativeTo:)`, so one switch can fall back to system fonts.
- **D4 — "Delete domain" from Herald.** Deleting a whole domain is an admin action in a triage client, and the API explicitly excludes admin APIs, so an upstream ask is likely refused on principle. *Recommend:* ship "Hide from Herald" plus an "Open in HQBase admin" link; drop the type-to-confirm delete sheet until upstream ever offers it. Need from you: the HQBase web admin URL pattern for a domain (or just the origin root).
- **D5 — Search field placement.** Design draws its own field in the list column; README says use `.searchable`. *Recommend:* keep toolbar `.searchable`, prompt names the scope ("Search acme.co").
- **D6 — Sidebar implementation.** *Recommend:* keep `List(selection:)` (keyboard, VoiceOver, type-select for free) and restyle rows; accept that macOS sidebar selection fill may not hit the exact `select` colour. Hand-drawn rows would mean re-building keyboard/a11y ourselves.
- **D7 — Where Sign Out / Add Account go.** The ellipsis menu disappears. *Recommend:* account card popover = switch + Add Account; Sign Out moves to Settings › Account.
- **D8 — Density setting home.** Design names it but no "General" page exists. *Recommend:* new Settings › General with Density only for now.

## 3. Phases (each: plan → build → real test → adversarial audit → commit)

**Phase 1 — Tokens & type (no behaviour change).**
Colour sets in `Assets.xcassets` (Any/Dark/Increase Contrast) → `MailTheme.Color.*`; 8 account tints + avatar text; label palette re-mapped; radius sm/md/lg/pill; motion micro/quick/scope/settle (reduce-motion gated at call site as today); typography tokens + bundled fonts (`project.yml` resources, `ATSApplicationFontsPath`); `MailTheme.Web` palette updated to match. Blast radius: every view; mostly token swaps. Update memory "Herald Design System and Accessibility".

**Phase 2 — Domain model + scope (logic, fully unit-tested, no UI).**
- `MailDomain` DTO (id, name, mailboxIDs) derived in `MailViewModel` from `mailboxes`.
- `DomainMonogram` pure func: 2 letters of first label; 3 on clash within the account; override wins.
- `DomainPreferences` (UserDefaults `domain.<accountID>.<domainID>.{monogram,includeInAll,countInBadge,notify,hidden}`), injected `defaults` like today.
- Replace `FolderSelection.mailboxID: String?` with a scope enum `.allDomains | .domain(id) | .mailbox(id)` + folder; resolve to `Set<String>?` of mailbox ids at the store boundary. `.allDomains` excludes hidden and `includeInAll == false` domains.
- Store: `mailboxID: String?` → `mailboxIDs: Set<String>?` on the 4 scope queries.
- Unread aggregation per domain; search domain filter; notifier + Dock badge honour `notify` / `countInBadge` / `hidden`.
- Account tint via `MailboxColorAssignment` hash keyed on account id + override; remove mailbox palette/overrides and one-time purge of `mailboxColor.*`.
- Persist level + selection per account (migrate `sidebar.mailbox.<accountID>` → new key once).
Blast radius: `MailViewModel` (+Labels/+Drafts/+Actions), `MailStore`, `NewMailNotifier`, `AppEnvironment` badge; tests: MailViewModelTests, SearchTests, LabelsTests, DraftsFolderTests, NotificationsTests, RowPresentationTests.

**Phase 3 — Sidebar drill-down.** Account card + popover (replaces `AccountSwitcher` and ellipsis menu), 3 levels with scope motion, filter fields (domains > 8, mailboxes always), domain context menu (Open / Mark All as Read / Domain Settings… / Hide), fixed-height sync slot kept. New `AccessibilityID`s; UI-test page objects (`MailWindowPages.swift` uses `mailboxPicker`) updated.

**Phase 4 — List column + thread.** Header band (serif title + caption), row rebuild (attribution rule, domain badge, density, chips max 3), thread header with back link / ⎋ / ⌘[, "N messages · M people", own-message avatar in account tint, "Message N of M" in the reading pane.

**Phase 5 — Reading pane.** Serif subject, sender block, To-chip with badge, toolbar order + primary New button, body 14/1.6 via web CSS vars.

**Phase 6 — Settings window.** Split-view settings: root (General, Notifications, Privacy, Account, Signatures, Domains list) → domain level (Overview, Mailboxes table, Signatures, Workflows disabled, Remove domain pinned). SERVER/HERALD tags. Route in `AppEnvironment` so "Domain Settings…" deep-links. Existing panes (Notifications, Privacy, Signatures) move in rather than being rewritten.

**Phase 7 — Remove domain + upstream.** Hide/unhide (Herald-only, listed in Settings for restore); admin link per D4. Add an entry to memory "Upstream PR Queue" only if you want to pursue a domain admin endpoint.

## 4. Risks
- Scope refactor (Phase 2) touches the most-tested code in the app; do it before any UI so the tests carry it.
- `List` sidebar styling limits (D6) — may need a spike before committing to exact visuals.
- Custom fonts in `WKWebView` need `@font-face` from the bundle (or fall back to system there).
- Settings `Scene` with a split view: window sizing/restoration quirks on macOS; spike early in Phase 6.

## 5. Memory to update as we go
"Herald Design System and Accessibility", "Herald Architecture" (scope model, drill-in), "herald-label-caching-and-ui-architecture" (labels placement), "Upstream PR Queue" (if D4 pursued).
