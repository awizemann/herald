# Handoff: Herald redesign (design system, sidebar, threads, domain settings)

## Overview
This is a redesign of Herald, the native macOS client for HQBase, in four parts:
1. A new visual system, "Modern Utility" (direction 1b).
2. A drill-down sidebar: **Account → Domains → Mailboxes → Folders**.
3. A thread view that drills in the same way inside the list column.
4. A Settings window that reuses the same layout (drill-down sidebar plus a detail pane), starting with per-domain settings.

## About the design files
The files in this bundle are **design references built in HTML**. They show the intended look and behaviour; they are not code to ship. Rebuild them in the existing SwiftUI app (`Herald/`) using its patterns:
- `MailTheme` stays the only source for tokens, symbols and metrics.
- `NavigationSplitView` provides the columns.
- `MailViewModel` holds the state.

Open `Herald Design System.dc.html` in a browser to see every turn on one pannable canvas. The mock windows are clickable.

## Fidelity
**High fidelity** for colour, type, spacing, radii, row anatomy and the sidebar and settings layouts. Rebuild these closely.

These parts are placeholders:
- **Icons:** the HTML uses Google Material Symbols as web stand-ins. Ship the **SF Symbols** listed in the icon map below.
- **Window chrome:** traffic lights, the toolbar and materials are approximated. Use the real macOS chrome (unified toolbar, sidebar material if you want it, `.searchable`).
- **Data:** all counts and data are fake.

---

## 1. Design tokens (MailTheme)
Add these as colour sets in the asset catalogue, with Any and Dark appearances plus an Increase Contrast variant where noted. Expose them as `MailTheme.Color.*`. The hex values are sRGB conversions of the OKLCH source values.

| Token | Role | Light | Dark |
|---|---|---|---|
| bg | List column / window canvas | #fbfcfd | #111315 |
| sidebar | Sidebar | #f1f3f5 | #0b0c0f |
| surface | Reading pane, settings detail, cards, fields | #ffffff | #191b1e |
| line | Borders, field outlines | #dbdee2 | #2e3035 |
| lineSoft | Row separators, hover fill, neutral chip fill | #e9ebee | #222428 |
| ink | Primary text | #13161c | #eef0f3 |
| ink2 | Secondary text (snippets, To:) | #4e535a | #a7abb1 |
| ink3 | Tertiary / meta (dates, counts, captions, section headers) | #6e7279 | #82868c |
| accent | Unread dot, primary button, selected icon, focus ring | #2e62c9 | #73a3fc |
| onAccent | Text on accent | #ffffff | #090d16 |
| select | Selected conversation/message row fill (the sidebar uses the system source-list selection; see §3.1) | #dbe9ff | #202e47 |
| star | Starred glyph | #e5a323 | #edb345 |
| danger | Failure, destructive | #c9302d | #f27166 |
| ok | Success ("On" in the mailbox table) | #2d8949 | (use systemGreen) |
| warn | Warning banner, info glyph | #c8800d | #eeb154 |
| match | Search-match highlight | #f6e697 | #6e5d14 |

**Account tints.** There are 8, all at the same lightness and chroma (OKLCH L 0.66, C 0.10); only the hue changes.
- The avatar is a solid tint with the initial in the matching dark "avatar text" colour.
- Washes are the tint at **22% fill + a 60% 1px inner border** (domain badge), or **16–18% fill + a 50–55% border** (chips).

| Name | Hue | Solid | Avatar text |
|---|---|---|---|
| Clay | 30 | #c87a6d | #301814 |
| Ochre | 70 | #b98749 | #2b1c08 |
| Moss | 118 | #8d9b51 | #1e220a |
| Sage | 160 | #55a57d | #0b2519 |
| Slate | 215 | #37a1b8 | #02242b |
| Dusk | 262 | #7092d0 | #151f32 |
| Plum | 310 | #a581c0 | #251a2d |
| Rose | 355 | #c27895 | #2e1720 |

Assign a tint per **account** with the existing stable FNV-1a hash (`MailboxColorAssignment`), keyed on the account ID instead of the mailbox address. The user can override it in **Settings › Account › Account colour** (§3.2).

**Label colours.** These translate the server's 10 `labelColors` names, at the same L and C: gray #929292, red #c87973, orange #c37f59, amber #b28b45, green #6aa36c, teal #33a6a0, blue #5a98cb, indigo #808dcf, purple #a082c3, pink #c0789b. Chip = 18% fill + 55% hairline, with the name in `ink`.

**Type.** Bundle the fonts (both are OFL): **Source Serif 4** for display, and **Geist** / **Geist Mono** for text and meta.

| Style | Font | Size / line height | Weight | Use |
|---|---|---|---|---|
| display | Source Serif 4 | 34 / 1.1, tracking −1.5% | 600 | Onboarding title |
| title | Source Serif 4 | 26–28 / 1.15, −1.5% | 600 | Reading-pane subject, settings page title |
| paneTitle | Source Serif 4 | 22 / 1.0, −1% | 600 | List column title ("All domains", "acme.co", "Inbox") |
| threadTitle | Source Serif 4 | 20 / 1.2 | 600 | Thread header subject |
| headline | Geist | 13 | 600 | Sender (unread), selected sidebar item |
| body | Geist | 13 / 1.45 | 400–500 | Rows, sidebar items |
| reading | Geist | 14 / 1.6 | 400 | Message body wrapper (web view CSS vars) |
| snippet | Geist | 12 / 1.4 | 400, ink2 | Row preview |
| caption | Geist | 11 | 400, ink3 | Sub-lines, notes |
| section | Geist | 11, +6% tracking, uppercase | 600, ink3 | "DOMAINS", "LABELS", "ON THIS MAC" |
| meta | Geist Mono | 11 (badges 9–10) | 400–600 | Dates, counts, domain badges, ⌘ shortcuts, SERVER/HERALD tags |

**Spacing.** Keep the existing 4pt grid: xxs 2 · xs 4 · sm 8 · md 12 · lg 16 · xl 20 · xxl 24 · xxxl 32.

**Radius.** sm 5 (rows, sidebar items, buttons) · md 7 (fields, row selection, account card) · lg 10 (cards, windows, sheets) · pill 999 (chips). Domain badges: 4 (row, 16pt), 5 (sidebar, 18pt), 6 (header, 22–24pt).

**Hit target.** 28pt minimum; icon buttons are 30×28.

**Shadows.** Sheet: `0 24 60 −12 rgba(0,0,0,.4)` + a 1px line ring. Context menu: `0 12 32 −8 rgba(0,0,0,.3)` + a 1px line ring. Prefer the system menu and sheet chrome where it exists.

**Motion.** Every token is gated at the call site on `accessibilityReduceMotion`, which turns it into a 0 ms cross-fade.
- micro: 120 ms ease-out (hover, press, star)
- quick: 180 ms ease-in-out (list ↔ thread swap, banners). This is the existing `MailTheme.Animation.quick`.
- scope: 220 ms ease-in-out (sidebar level change; the rows cross-fade)
- settle: 260 ms spring 0.9 (sheets, account popover)

**Density** (user setting, Comfortable by default):

| | Comfortable | Compact |
|---|---|---|
| Row vertical padding | 14 | 7–8 |
| Snippet lines | 2 | 1 |
| Sidebar item height | 30 | 26 |
| Attribution | Own line | Inline with sender |

---

## 2. Identity at scale
One install can hold up to 8 accounts × 20 domains × 100 mailboxes. Each level gets the cue that still works at that count:
- **Account → colour.** One of the 8 tints, shown as a solid avatar with the initial. Nothing else gets its own hue.
- **Domain → badge.** Two letters from the first label of the domain (acme.co → AC, northwind.io → NO, fieldnotes.press → FI). If two domains in **one account** clash, both use three letters (NOR / NOT). The tile is a wash of the account's tint. The user can override it (Settings › Domain › Overview).
- **Mailbox → name only.** The local part (`sales@`), with the domain after it in ink3 where needed. No colour.
- **Never colour alone.** Every tint sits beside letters or a name, and every wash has a hairline border.

**Attribution rule for rows:** show only the levels the current scope hasn't fixed.
- All domains: badge + mailbox (`[AC] sales@ · Mara Okafor`)
- One domain: mailbox only
- One mailbox: nothing
- A future multi-account scope would put the account dot first.

**Migration note:** the per-mailbox colour palette (`MailTheme.mailboxPalette`, `MailboxSettingsPane`) is replaced by per-account tints. Stored `mailboxColor.*` overrides become obsolete.

---

## 3. Screens

### 3.1 Mail window (`Herald Window.dc.html`)
Three columns at a default width of 1180, with a 52pt unified toolbar band. **Sidebar 252 · list 344 · reading pane flexible (min 360).**

**Sidebar: a native macOS source list** (`List` with `.listStyle(.sidebar)`). Draw rows with the system sidebar selection:
- Focused: accent fill (drawn as #0063e1 in the mocks), white text, icons and counts.
- Unfocused: grey fill (ink at about 10%), primary text.

The mocks approximate what the system draws; the token `select` is a target for non-`List` surfaces only. Hover is `lineSoft`. Rows are 30pt (26 in Compact), inset radius about 6.

Top to bottom:
1. Traffic-light band (52pt).
2. **Account card.** It **replaces the old sidebar ellipsis menu**.
   - Layout: margin 0 10 10, padding 8 10, radius md, surface fill, lineSoft border (line while the popover is open).
   - Contents: 26pt tint avatar, then the account name (13/600) over a caption ("5 domains · synced now"), then the total unread (mono 11/600, ink2), then `chevron.up.chevron.down`.
   - The sync-status slot keeps its fixed height, per the existing `SyncStatusLabel` rule. Its "Sign in again" state still lives here.
   - **Popover** (290 wide, radius md, standard menu shadow):
     - One row per account: a checkmark column (✓ on the current account), 24pt tint avatar, name (600 if current) over its server host, and unread (mono 11/600).
     - A divider, then **Add Account…** and **Settings…** (⌘,). Settings… opens Settings › Account for the current account.
   - **Where the old menu's actions went:** Add Account… → this popover. Sign Out → Settings › Account (§3.2).
3. A 1px lineSoft divider.
4. **One of three levels.** Only one shows at a time; switch between them with the `scope` motion.
   - **Level 1, Domains + Labels:**
     - Header "DOMAINS", with a filter glyph that turns into a field once there are more than 8 domains.
     - "All domains" (`tray.2`, selected by default), then each domain: 18pt badge, name (600 if it has unread), unread (mono 11/600, hidden when 0), `chevron.right`.
     - Clicking a domain goes to level 2.
     - Then **"LABELS"**: workspace labels (HQBase labels belong to the whole workspace). Each row: colour dot, name, count (conversations in the current folder).
     - Clicking a label opens it (see Labels below); clicking it again, or "All domains", clears it.
   - **Level 2, Mailboxes:**
     - Back link "‹ Domains".
     - Header: 24pt badge, domain name (14/600), and a **gear** (Domain Settings…).
     - A "Filter N mailboxes" field.
     - "All mailboxes" (selected by default), then each mailbox: `at`, **local part** (600 if unread) + domain in ink3, unread, chevron.
   - **Level 3, Folders:**
     - Back link "‹ acme.co".
     - Header: badge + `sales@` + domain.
     - Folders: Inbox (unread), Starred, Sent, Drafts (total), Archived, Trash.
     - No labels at this level.
5. **Domain context menu** (right-click a domain row): Open acme.co · Mark All as Read · — · **Domain Settings…** · Hide from Herald.

**Scope and folder are independent.**
- The *scope* comes from the sidebar: All domains / one domain / one mailbox. The *folder* is one of Inbox, Starred, Sent, Drafts, Archived, Trash.
- The folder picked at any level is kept when the user drills down or back. For example, pick Sent at "All domains", open acme.co, and the list shows acme.co · Sent.
- At level 3 the sidebar folder list and the folder menu write the same value.

**Labels:**
- An open label **stays open while drilling in, and narrows with the scope**. For example, Client at level 1, then open acme.co, and the list shows acme.co · Inbox filtered to Client.
- Label and folder **combine**: the list shows conversations in the folder that carry the label.
- An open label shows as a removable chip in the header caption (tint wash, name, × to clear).
- The sidebar highlights the label row only at level 1. Deeper, the chip is the indicator.

**Drafts:**
- Drafts at "All domains" lists **every** draft, including drafts with no mailbox. Those rows show a "No mailbox" tag (10pt, ink3, 1px line outline) in place of the badge and mailbox, with "Draft" in `danger` as the sender.
- Drafts inside a mailbox that has none shows an empty state: `doc.text` glyph, "No drafts in team@" (serif 18), "Drafts that aren't tied to a mailbox are listed under All domains › Drafts." (12, ink3), and a **Show All Drafts** button that returns to level 1, keeping Drafts.
- Other empty folders: "Nothing in {Folder}" + the scope.

**List column** (bg):
- **Toolbar band (52pt):** the native toolbar search field (`.searchable(placement: .toolbar)`), sitting above the list column. The placeholder names the scope: "Search all domains" / "Search acme.co" / "Search sales@acme.co". There is no in-column field and no drawn ⌘F hint; ⌘F still focuses it.
- **Header band** (padding 14 20 10, gap 5):
  - Levels 1–2: the title is a **folder menu**: "Inbox" in serif 22 + `chevron.down` (ink2), hover lineSoft, radius 6.
    - The menu (224 wide, below the title) lists the six folders with a checkmark column, symbol, name and count (Inbox unread, Drafts total). Picking one sets the folder and closes the menu.
  - Level 3: the same title, **plain** (the sidebar already lists the folders).
  - Caption (11, ink3): "{scope} · {folder}", e.g. "All domains · Sent", "acme.co · Inbox", "sales@acme.co · Drafts". It's followed by the label chip when a label is open.
- **Conversation row:** unchanged. Grid `10 | 1fr | auto`, gap 10, padding (14 or 7) × 12, radius md, lineSoft separators hidden next to the selection. Unread dot, attribution (§2) + sender, subject, snippet (2 lines, or 1 in Compact), optional label chips. Trailing column: date over [count][star][chevron if a thread]. Selected = `select` fill (+ a 1px accent border with Differentiate Without Color).

**Thread view** (list column, replaces the list): unchanged.
- Opens when the user selects a row whose count is more than 1. Back link "‹ {folder}"; ⎋ and ⌘[ also go back.
- Header: subject (serif 20) + attribution + "N messages · M people".
- **Newest first**, with the newest selected.
- Message rows: 28pt avatar (your own messages use the account tint), unread dot, sender, To:, snippet, date + star.
- The reading pane shows "Message N of M" (N counts oldest-first).

**Reading pane** (surface): unchanged.
- Toolbar: reply, reply all, forward | archive, trash, labels | refresh, then primary **New**.
- Subject in serif 28, sender block with a "To [badge] address" chip, label chips, then the body at 14/1.6 (max 600).
- Drafts and Sent say "From" in place of "To". When nothing is selected: "Nothing selected" empty state.

### 3.2 Settings window (`Herald Settings.dc.html`)
Two columns at a default size of 1000 × 680. **Sidebar 240 (native source list, same selection rules as §3.1) · detail flexible.**

This layout is the template for every future settings area (Workflows and so on).

**Sidebar:**
- The account card (caption = server origin).
- **Root level:**
  - "HERALD": General · Notifications · Privacy
  - "ACCOUNT": Account · Signatures
  - "DOMAINS": each visible domain + chevron
- **Domain level:**
  - "‹ Settings", then the header (badge + name).
  - Sections: Overview · Mailboxes (count) · Signatures (count) · Workflows (disabled, 50% opacity, "LATER").
  - Pinned to the bottom: **Remove domain**, now a neutral item (`eye.slash`), because nothing on it is destructive.

**Detail pane:** breadcrumb caption, then the page title in serif 26. Max width 720, padding 4 40 32. Grouped cards: 1px line border, radius lg, rows 12 × 16. Every row is tagged **SERVER** (ink3 outline, from the HQBase API) or **HERALD** (accent outline, this Mac only).

**Root pages:**
- **General** (new): "MESSAGE LIST" card.
  - Density: segmented control Comfortable / Compact [HERALD], "Applies to all accounts".
  - Below it, two live previews side by side: the same selected row at Comfortable (14pt padding, 2-line snippet, attribution on its own line) and Compact (7pt, 1 line, attribution inline). The chosen one has a 2px accent ring.
- **Notifications:** unchanged from today: "Notify me about new mail" (with the macOS note) and "Show unread count on the Dock icon".
- **Privacy:** unchanged from today: "Share anonymous usage" with the existing explanation copy.
- **Account** (new; per account, following the account card):
  - "SERVER" card:
    - Server = the origin (mono) [SERVER].
    - Sync = the status caption ("Synced just now · checks every 2 minutes while Herald is open") + a **Sync Now** button.
  - "ON THIS MAC" card: **Account colour**. The 8 tint swatches (18pt; the current one has a 2pt surface gap + an ink ring), then **Reset** (enabled once overridden) [HERALD]. **This is where the account-tint override lives.**
  - Sign-out card: "Sign out of Wizemann Studio", "Removes this account and its cached mail from Herald on this Mac. Other accounts keep syncing. Nothing changes on the server.", and a **Sign Out…** button (outline, danger text). **Sign Out moved here from the old ellipsis menu.**

**Domain pages:**
- **Overview:**
  - "DOMAIN" card: Name [SERVER] · Mailboxes you can access [SERVER] · Monogram (preview + 2–3 letter field) [HERALD].
  - "ON THIS MAC" toggles [HERALD]: Include in "All domains" · Count unread in the Dock badge · Notify me about new mail.
- **Mailboxes:** a read-only table: Address (+ Primary pill) · Sender name · Receive · Send. Source: `GET /api/v1/mailboxes` → `addresses[]` by `mailDomainId`.
- **Signatures:** domain-scoped signatures (`/api/v1/signatures/manage`, scope `domain`): name, Default pill, preview, Edit / more, **New Signature**. Non-admins see them read-only, with the server's message.
- **Remove domain:**
  1. "Hide from Herald" [HERALD]: removes the domain from the sidebar, counts and notifications on this Mac, with a **Hide Domain** button.
  2. **"HIDDEN DOMAINS"** list: badge (60% opacity), domain, "Hidden {date} · N mailboxes", and **Restore**. When the list is empty it reads "No hidden domains."
  3. A neutral card (bg fill, line border): "Delete this domain on the server" [SERVER], "Deleting a domain and its mailboxes is managed by a workspace admin in HQBase. Herald can't delete domains.", and an **Open in HQBase Admin ↗** button (outline) that opens the server's admin page in the browser.

  Herald has no server-side domain delete and no confirmation sheet. Mail API v1 has no domain endpoints and deliberately leaves out administrative operations.

---

## 4. State (MailViewModel additions)
- `sidebarLevel`: `.domains` | `.mailboxes(domainID)` | `.folders(domainID, mailboxID)`.
- `scope`: `.allDomains` | `.domain(id)` | `.mailbox(id)`. This is derived from the sidebar level.
- `folder`: `ConversationFolder` + drafts. It is **independent of scope**: drilling down or back never resets it. Set it from the header folder menu (levels 1–2) or the sidebar folder list (level 3).
- `label`: `MailLabel.ID?`.
  - Opened from level 1 only, and kept while drilling in.
  - The list is filtered by scope ∩ folder ∩ label.
  - It is cleared by the header chip's ×, by reselecting the label, or by "All domains".
- Drafts at `.allDomains` include drafts with no `mailboxID`. Drafts in narrower scopes include only that scope's drafts.
- Unread counts are aggregated per domain and per mailbox. Domains are grouped by `MailboxAddress.mailDomainID`, and the display name is the domain part of the address. Label counts are per label within the current folder.
- Persist `sidebarLevel`, `scope`, `folder` and `label` per account (like `sidebar.mailbox.<accountID>` today) and restore them at launch.
- Thread: the existing `isShowingThread` / `threadMessages`, sorted **descending**, with the newest selected.
- Search: `.searchable` on the split view with `placement: .toolbar`, and a prompt derived from `scope`.
- Herald-only preferences (UserDefaults):
  - `domain.<accountID>.<domainID>.{monogram, includeInAll, countInBadge, notify, hidden, hiddenAt}`
  - `account.<accountID>.tint` (a palette token; unset = hash default)
  - `list.density` (`comfortable` | `compact`)
- Removed: the sidebar account ellipsis menu (`AccessibilityID.Sidebar.accountOptions`, `.addAccount`, `.signOut`). Re-home those identifiers on the popover and on Settings › Account.

## 5. Icon map (MailTheme symbols)
| Role | SF Symbol |
|---|---|
| Inbox | tray |
| Starred | star / star.fill |
| Sent | paperplane |
| Drafts | doc.text |
| Archived | archivebox |
| Trash | trash |
| All domains / All mailboxes | tray.2 |
| Mailbox | at |
| Labels | tag |
| New message | square.and.pencil |
| Refresh | arrow.clockwise |
| Reply / Reply All / Forward | arrowshape.turn.up.left / .left.2 / .right |
| Attachment | paperclip |
| Session lock | lock.fill |
| Warning | exclamationmark.triangle.fill |
| Remote images | photo |
| Drill down / back | chevron.right / chevron.left |
| Account switcher | chevron.up.chevron.down |
| Domain settings | gearshape |
| Settings: General / Notifications / Privacy / Account / Signatures | slider.horizontal.3 / bell / hand.raised / person.crop.circle / signature |
| Workflows | point.3.connected.trianglepath.dotted |
| Mailbox receive/send on / off | checkmark.circle.fill / nosign |
| Remove domain / hidden | eye.slash |
| Open in HQBase Admin | arrow.up.right.square |
| Folder menu / current item | chevron.down / checkmark |
| Clear label filter | xmark.circle.fill |
| Empty: nothing selected / no results | envelope.open / magnifyingglass |

## 6. Assets
`assets/herald-icon-512.png` is the existing app icon, taken from `Herald/Assets.xcassets/AppIcon.appiconset`. There are no other images.

## 7. Screenshots (`screenshots/`)
- `1b-design-system.png`: the full reference sheet.
- `2a-1-sidebar-domains.png`, `2a-2-sidebar-mailboxes.png`, `2a-3-sidebar-folders.png`: the three sidebar levels (labels now at level 1, toolbar search).
- `3a-1-thread-mailbox.png`, `3a-2-thread-all-domains.png`: the thread view.
- `4a-0-entry-points.png`: the domain context menu and the gear.
- `4a-1-domain-overview.png`, `4a-2-domain-mailboxes.png`, `4a-3-domain-signatures.png`, `4a-4-remove-domain.png`: the Settings domain pages. Remove domain now shows Hide, Hidden domains and Open in HQBase Admin.
- `5a-1-folder-menu.png`: the folder menu open at level 1.
- `5a-2-sent-all-domains.png`, `5a-3-drafts-all-domains.png`: a folder across the whole scope, including drafts with no mailbox.
- `5a-4-label-level1.png`, `5a-5-label-drilled.png`: a label at level 1, and the same label kept after drilling into acme.co.
- `5a-6-drafts-empty.png`: the Drafts empty state inside a mailbox.
- `5a-7-sidebar-unfocused.png`: the source-list selection when the sidebar isn't focused.
- `5a-8-account-popover.png`: the account card popover.
- `5b-1-settings-general.png`, `5b-2-settings-general-compact.png`: Settings › General.
- `5b-3-settings-account.png`: Settings › Account.

## 8. Files
- `Herald Design System.dc.html`: the canvas with every turn (5 Engineering revisions, 4 Domain settings, 3 Thread view, 2 Sidebar drill-down, 1b Design system). The root element defines all tokens as CSS variables.
- `Herald Window.dc.html`: the interactive mail window (sidebar levels, labels, folder menu, account popover, list, thread, empty states, reading pane).
- `Herald Settings.dc.html`: the interactive settings window (General, Notifications, Privacy, Account, and domain Overview, Mailboxes, Signatures and Remove domain).
- `DS Board.dc.html`: the design-system reference sheet.
- `support.js`: the runtime that renders the `.dc.html` files. Open the design system file in a browser.
