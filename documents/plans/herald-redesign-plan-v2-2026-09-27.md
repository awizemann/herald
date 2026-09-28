# Herald redesign — implementation plan v2 (2026-09-27)

Source: `design/design_handoff_herald_redesign 2/` (supersedes `design/design_handoff_herald_redesign/` and plan v1 `plans/herald-redesign-plan-2026-09-27.md`).
Status: PLAN ONLY — nothing implemented.

## 1. What changed in the handoff (v1 → v2)

All seven engineering points were taken:

| # | v1 issue | v2 resolution |
|---|---|---|
| 1 | Folders only inside a mailbox | Scope and folder are independent. Levels 1–2: the pane title is a folder menu ("Inbox ▾"); level 3: the sidebar folder list. The folder survives drilling down and back. |
| 2 | Labels only at mailbox level | Labels on level 1. An open label stays open while drilling and narrows with the scope; shown as a removable chip in the header caption. Label **combines with folder** (scope ∩ folder ∩ label). |
| 3 | Drafts with no mailbox | All domains › Drafts lists every draft; mailbox-less ones carry a "No mailbox" tag. Empty state per mailbox with "Show All Drafts". |
| 4 | Server domain delete | Dropped. Remove domain = Hide Domain + Hidden domains list with Restore + "Open in HQBase Admin ↗". No confirmation sheet. |
| 5 | In-column search | Native toolbar `.searchable`, placeholder names the scope. |
| 6 | Ellipsis menu | Account card popover: accounts, Add Account…, Settings… (opens Settings › Account). Sign Out → Settings › Account. Account colour override → Settings › Account. |
| 7 | Density / sidebar | New Settings › General (Density + previews). Sidebar = native source list with system selection; `select` token only for non-`List` surfaces. |

## 2. Grounding (still true from v1)

- **No new API needed for anything in v2.** Each mailbox has exactly one address (`Mailbox.addresses` is `minItems 1, maxItems 1`) carrying `mailDomainId`, so domains, names, mailbox counts and unread totals are derived client-side.
- **Domain scope = a set of mailbox ids.** `MailStore` scope queries take `mailboxID: String?` today; they become `Set<String>?`. Sync (per mailbox) is untouched.
- **Domain search** = all-mailbox server search filtered client-side.
- **Per-domain unread** = sum of the existing per-(mailbox, folder) `unreadCounts`.
- **Domain signatures** reuse `SignatureManagementService` / `SignatureSettingsModel`.
- Removed: `MailTheme.mailboxPalette`, `mailboxColorOverrides`, `MailboxSettingsPane`, stored `mailboxColor.*` keys (purge once).

## 3. New findings in v2 (need your call — recommendation first)

- **N1 — Sign-out copy is wrong.** Settings › Account says "Nothing changes on the server." Sign-out revokes the account's OAuth grant on the server (`AuthCoordinator.signOut`). *Recommend:* "Your mail on the server isn't touched." — true and still reassuring.
- **N2 — "Checks every 2 minutes" is not a fixed fact.** Cadence is 15 s / 60 s polling, stretched to 120 s / 300 s while the wake socket is connected (`SyncEngine` `SyncCadence`). *Recommend:* drop the cadence clause; show the existing status text ("Synced just now") only.
- **N3 — Labels no longer span folders.** Today a label listing shows every labelled thread whatever its folder. In v2, Inbox + Client hides a Client thread that was archived until you switch to Archived. That is what the design specifies; I'm flagging it because it is a behaviour change, not a restyle. *Recommend:* accept as designed.
- **N4 — Label counts per folder.** "Count = conversations in the current folder" needs the label index (`MailStore.labelIndex`) to also read each row's folder. Cheap (one more fetched column), noted as work, no decision needed.
- **N5 — Admin link target.** "Open in HQBase Admin ↗" needs a URL. *Recommend:* the account origin root unless you give me HQBase's admin path for a domain.
- **N6 — Domain unread counts under a non-Inbox folder.** The sidebar's domain/mailbox counts: Inbox unread always (my assumption; the handoff doesn't say), even when the list shows Sent. *Recommend:* Inbox unread always — a Sent unread count is meaningless.

## 4. Phases (each: plan → build → real test → adversarial audit → commit)

**Phase 1 — Tokens & type (no behaviour change).**
Colour sets (Any/Dark/Increase Contrast) → `MailTheme.Color.*`; 8 account tints + avatar text; label palette; radius sm/md/lg/pill; motion micro/quick/scope/settle (reduce-motion gated at the call site); typography tokens with bundled Source Serif 4 / Geist / Geist Mono through `Font.custom(_:size:relativeTo:)` (one place to fall back to system); `MailTheme.Web` palette + reading font. Update memory "Herald Design System and Accessibility".

**Phase 2 — Scope, folder, label, domain model (logic only, unit-tested).**
- `MailDomain` DTO (id, name, mailboxIDs) derived from `mailboxes`; `DomainMonogram` (2 letters, 3 on clash within the account, override wins).
- Replace `FolderSelection(mailboxID:folder:)` + `SidebarItem` with: `scope` (`.allDomains | .domain(id) | .mailbox(id)`), `folder` (the 5 conversation folders + drafts), `label: MailLabel.ID?` — three independent axes; `sidebarLevel` derived for the UI.
- Store scope queries → `Set<String>?` of mailbox ids. `.allDomains` excludes hidden and `includeInAll == false` domains.
- Label listing = folder list ∩ label (today it spans all folders; `showLabel` / `reloadConversations` change); `LabelIndex` gains per-folder counts (N4).
- Drafts filtered by scope; `.allDomains` includes `mailboxID == nil`.
- `DomainPreferences` (`domain.<accountID>.<domainID>.{monogram,includeInAll,countInBadge,notify,hidden,hiddenAt}`), `account.<accountID>.tint`, `list.density`.
- Dock badge honours `countInBadge`/`hidden`; `NewMailNotifier` candidates filtered by `notify`/`hidden` (needs mailbox→domain lookup).
- Persist scope/folder/label/level per account; one-time migration of `sidebar.mailbox.<accountID>`; one-time purge of `mailboxColor.*`.
- Account tint via `MailboxColorAssignment` keyed on account id + override.
Blast radius: `MailViewModel` (+Labels, +Drafts, +Actions), `MailStore` (+Labels), `NewMailNotifier`, `AppEnvironment` badge. Tests: MailViewModelTests, SearchTests, LabelsTests, DraftsFolderTests, NotificationsTests, RowPresentationTests.

**Phase 3 — Sidebar.** Account card + popover (replaces `AccountSwitcher` and the ellipsis menu; re-home `AccessibilityID.Sidebar.addAccount`/`.signOut`), three levels on `List(.sidebar)` with scope motion, Labels on level 1, filter fields (domains > 8; mailboxes always), domain context menu (Open / Mark All as Read / Domain Settings… / Hide), gear → Domain Settings. Fixed-height sync slot kept. UI-test page objects (`MailWindowPages.swift`) updated.

**Phase 4 — List column + thread.** Toolbar search prompt per scope; header band with the folder menu (levels 1–2, counts: Inbox unread / Drafts total) or plain title (level 3); caption "{scope} · {folder}" + label chip with ×; row rebuild (attribution rule, domain badge, density, "No mailbox" draft tag); empty states (Drafts per mailbox with Show All Drafts, "Nothing in {Folder}"); thread header, back link / ⎋ / ⌘[, "N messages · M people", own-message avatar in account tint.

**Phase 5 — Reading pane.** Serif subject, "Message N of M", sender block with To/From chip + badge, toolbar order + primary New, body 14/1.6 via web CSS vars, "Nothing selected" state.

**Phase 6 — Settings window.** Split-view Settings (spike window sizing first). Root: General (new — Density + previews), Notifications (moved as is), Privacy (moved as is), Account (new — server, sync + Sync Now, account colour + Reset, Sign Out… with confirmation), Signatures (moved), Domains list. Domain level: Overview (name, mailbox count, monogram field, three toggles), Mailboxes table, Signatures filtered to the domain, Workflows disabled, Remove domain pinned. SERVER/HERALD tags. A settings route in `AppEnvironment` so "Domain Settings…" and the popover's "Settings…" deep-link.

**Phase 7 — Hide domain.** Hide Domain / Hidden domains list (date, mailbox count) / Restore; hidden domains drop out of sidebar, counts, badge and notifications; admin link (N5).

## 5. Risks
- Phase 2 rewrites the most-tested state in the app — done before UI so the tests carry it.
- Custom fonts inside `WKWebView` need bundled `@font-face` (or system fallback there).
- Split-view `Settings` scene sizing/restoration quirks — spike at the start of Phase 6.
- Label ∩ folder changes what users see for existing labels (N3).

## 6. Memory to update as we go
"Herald Design System and Accessibility", "Herald Architecture" (scope/folder/label model), "herald-label-caching-and-ui-architecture" (labels at level 1, label ∩ folder), "Herald Project Overview" if the navigation summary lives there.
