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
| select | Selected row / sidebar item fill | #dbe9ff | #202e47 |
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

Assign a tint per **account** with the existing stable FNV-1a hash (`MailboxColorAssignment`), keyed on the account ID instead of the mailbox address. The user can override it.

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
Three columns at a default width of 1180, with a 52pt toolbar band. **Sidebar 252 · list 344 · reading pane flexible (min 360).**

**Sidebar**, top to bottom:
1. Traffic-light band (52pt).
2. **Account selector card:** margin 0 10 10, padding 8 10, radius md, surface fill, lineSoft border.
   - Contents: 26pt avatar, then the account name (13/600) over a caption ("5 domains · synced now"), then the total unread (mono 11/600, ink2), then the `chevron.up.chevron.down` glyph.
   - It opens a popover to switch accounts or add one.
   - The sync-status slot keeps its fixed height, per the existing `SyncStatusLabel` rule.
3. A 1px lineSoft divider.
4. **One of three levels.** Only one shows at a time; switch between them with the `scope` motion.
   - **Level 1, Domains:**
     - Section header "DOMAINS", with a filter glyph on the right that turns into a filter field once there are more than 8 domains.
     - Rows are 30pt high, padding 0 10, radius sm.
     - "All domains" comes first (`tray.2`, and selected by default), then each domain: 18pt badge, domain name (600 if it has unread), unread count (mono 11/600, ink2; hidden when 0), then `chevron.right` in ink3.
     - Clicking a domain goes to level 2 and sets the list scope to that domain.
   - **Level 2, Mailboxes:**
     - Back link "‹ Domains" (12, ink2).
     - Header: 24pt badge, domain name (14/600), and a **gear button** (Domain Settings…).
     - A "Filter N mailboxes" field (26pt, surface fill, lineSoft ring). A domain can have 100 mailboxes.
     - "All mailboxes" (selected by default, with the domain's unread), then each mailbox: `at` glyph, **local part** (600 if unread) + domain in ink3, unread count, chevron.
   - **Level 3, Folders:**
     - Back link "‹ acme.co".
     - Header: badge + `sales@` + domain in ink3.
     - Folders: Inbox (unread), Starred, Sent, Drafts (total), Archived, Trash.
     - Then "LABELS" with a colour dot, name and a thread total.
     - Labels appear **only at this level** (open question: should they also show at the domain level?).
   - Selected item: `select` fill, accent icon, weight 600. Hover: `lineSoft` fill.
5. **Domain context menu** (right-click a domain row): Open acme.co · Mark All as Read · — · **Domain Settings…** · Hide from Herald.

**List column** (bg):
- Header band: pane title in serif 22, sub-line caption ink3.
  - Level 1: "All domains" / "Wizemann Studio · 25 unread"
  - Level 2: "acme.co" / "All mailboxes · 14 unread"
  - Level 3: "Inbox" / "sales@acme.co · 8 unread"
- Search field: 30pt, radius md, surface, line border, with a ⌘F hint. The placeholder names the scope ("Search acme.co").
- **Conversation row:**
  - Grid of `10 | 1fr | auto`, gap 10, padding (14 or 7) × 12, radius md.
  - Separator is a 1px lineSoft line under each row, hidden next to the selection.
  - Column 1: an 8pt unread dot (accent), 5pt from the top.
  - Column 2:
    - Line 1: attribution (see §2) + sender (600 if unread, otherwise 500).
    - Line 2: subject (600 if unread).
    - Line 3: snippet (12, ink2, 2 lines).
    - Optional label chips (max 3, then +n).
  - Column 3: date (mono 11, ink3) over [count pill][star][`chevron.right` if the thread has more than one message].
  - Selected = `select` fill. With Differentiate Without Color on, also draw a 1px accent border.

**Thread view** (list column, replaces the list):
- Opens when the user selects a row whose count is more than 1. This is the existing `isShowingThread` behaviour.
- Back link "‹ {folder or scope title}". ⎋ and ⌘[ also go back.
- Header: subject (serif 20), then the attribution for the scope + "N messages · M people", then a lineSoft bottom border.
- **Messages are newest first**, the same order as the list, and the newest is selected on entry.
- Message row: grid `28 | 1fr | auto`.
  - 28pt avatar: initials on lineSoft; **your own messages use the account's tint**.
  - Unread dot overlaid at the avatar's top-left, with a 2pt bg ring.
  - Sender (600 if unread), "To: …" (11, ink3), snippet, then date + star.
- The reading pane shows "Message N of M" (mono 11, ink3) above the subject. N counts oldest-first, so the newest is "M of M".

**Reading pane** (surface):
- Toolbar band, right-aligned: reply, reply all, forward | archive, trash, labels | refresh, then the primary **New** button (accent, 28pt).
- Content padding 32 × 44:
  - Subject in serif 28.
  - Sender block: 36pt avatar, name + address, "To [badge] sales@acme.co" chip, date on the right in mono.
  - Label chips, then a divider.
  - Body at 14/1.6, max width 600.
  - Attachment cards: radius md, line border.

### 3.2 Settings window (`Herald Settings.dc.html`)
Two columns at a default size of 1000 × 680. **Sidebar 240 · detail flexible.**

This layout is the template for every future settings area (Workflows and so on): a drill-down sidebar of sections on the left, a detail pane on the right.

**Sidebar:**
- The same account card as the mail window, but the caption is the server origin.
- **Root level:**
  - "HERALD": General, Notifications, Privacy
  - "ACCOUNT": Account, Signatures
  - "DOMAINS": each domain with its badge and a chevron
- **Domain level:**
  - Back link "‹ Settings", then a header with the badge and domain name.
  - Sections: Overview · Mailboxes (count) · Signatures (count) · Workflows (disabled at 50% opacity, "LATER" meta).
  - Pinned to the bottom: **Remove domain** (danger text and icon; selected fill = 12% danger).

**Detail pane:**
- Breadcrumb caption ("Settings › Wizemann Studio › acme.co"), then the page title in serif 26.
- Content max width 720, padding 4 40 32.
- Grouped cards: 1px line border, radius lg, rows padded 12 × 16, lineSoft separators.
- **Where each setting lives:** every row carries a small mono tag. **SERVER** (ink3 outline) means it comes from the HQBase API. **HERALD** (accent outline) means it's stored on this Mac only.

**Domain pages:**
- **Overview**
  - "DOMAIN" card: Name [SERVER] · Mailboxes you can access [SERVER] · Monogram (preview + 2–3 letter field) [HERALD].
  - "ON THIS MAC" card, toggles (34×20, accent when on):
    - Include in "All domains"
    - Count unread in the Dock badge
    - Notify me about new mail (per domain; defaults to the global setting)
- **Mailboxes:** a read-only table with columns Address (local part + domain, Primary pill) · Sender name · Receive · Send (check_circle ok / block ink3). Source: `GET /api/v1/mailboxes` → `addresses[]` filtered by `mailDomainId`.
- **Signatures:**
  - Domain-scoped signatures (`/api/v1/signatures/manage`, scope `domain`): name, Default pill, one-line preview, then Edit and a more button. "New Signature" is a primary button.
  - Non-admins see the list read-only, with the server's permission message (`SignatureManagementService`).
- **Remove domain:**
  - "Hide from Herald" [HERALD] is a local and reversible action: it hides the domain from the sidebar, the counts and notifications. Hidden domains are listed and restored from Settings.
  - "Delete domain" [SERVER] sits in a danger card (40% danger border, 4% fill) with a **Delete Domain…** button.
  - The confirmation sheet asks the user to type the domain name. Its Delete button is disabled until the typed name matches exactly.
  - ⚠ **Mail API v1 has no domain endpoints.** A server-side delete needs a new upstream HQBase endpoint. Until then the button opens the domain in the HQBase web admin, and an info line in the card says so.

---

## 4. State (MailViewModel additions)
- `sidebarLevel`: `.domains` | `.mailboxes(domainID)` | `.folders(domainID, mailboxID)`
- `selection` gains a domain scope. The scope is one of: all domains in the account / one domain / one mailbox + folder.
- Unread counts are aggregated per domain and per mailbox. Domains are grouped by `MailboxAddress.mailDomainID`; the display name is the domain part of the address.
- Store the level and selection per account (like `sidebar.mailbox.<accountID>` today), and restore them at launch.
- Thread: the existing `isShowingThread` / `threadMessages`, sorted **descending** by date, with the default selection at the newest.
- Herald-only per-domain preferences in UserDefaults, keyed `domain.<accountID>.<domainID>.*`: `monogram`, `includeInAll`, `countInBadge`, `notify`, `hidden`.
- Density preference: `comfortable` | `compact`.

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
| Empty: nothing selected / no results | envelope.open / magnifyingglass |

## 6. Assets
`assets/herald-icon-512.png` is the existing app icon, taken from `Herald/Assets.xcassets/AppIcon.appiconset`. There are no other images.

## 7. Screenshots (`screenshots/`)
- `1b-design-system.png`: the full reference sheet, including the light and dark in-situ windows.
- `2a-1-sidebar-domains.png`, `2a-2-sidebar-mailboxes.png`, `2a-3-sidebar-folders.png`: the three sidebar levels.
- `3a-1-thread-mailbox.png`, `3a-2-thread-all-domains.png`: the thread view, opened inside one mailbox and from All domains.
- `4a-0-entry-points.png`: the domain context menu and the gear in the domain header.
- `4a-1-domain-overview.png`, `4a-2-domain-mailboxes.png`, `4a-3-domain-signatures.png`, `4a-4-remove-domain.png`: the Settings domain pages. The last one includes the delete confirmation sheet.

## 8. Files
- `Herald Design System.dc.html`: the canvas with every turn (4 Domain settings, 3 Thread view, 2 Sidebar drill-down, 1b Design system). The root element defines all tokens as CSS variables.
- `Herald Window.dc.html`: the interactive mail window (sidebar levels, list, thread, reading pane, domain context menu).
- `Herald Settings.dc.html`: the interactive settings window (root and domain levels, the four domain pages, the delete confirmation sheet).
- `DS Board.dc.html`: the design-system reference sheet (identity, colour, type, spacing, icons, chips, rows, sidebar items, buttons, banners, onboarding, empty states, motion, in-situ windows).
- `support.js`: the runtime that renders the `.dc.html` files. Open the design system file in a browser.
