# Herald redesign — orchestration + sub-agent brief (2026-09-27)

Plan: `documents/plans/herald-redesign-plan-v2-2026-09-27.md` (read it first — §3 decisions N1–N5 are APPROVED by Alan as recommended).
Design (read-only, untracked, lives ONLY in the main checkout): `/Users/awizemann/Developer/hqbase-mac/design/design_handoff_herald_redesign 2/` — `README.md` is the spec; `screenshots/` are the visual truth; `.dc.html` files are interactive mocks (plain HTML/JS; read the source for exact values).
Integration branch: `redesign` (main checkout). Never push. Alan's standing note: functionality gaps discovered after dogfooding are handled later — build what the design says.

## Phases (Memophant task per phase)

| Phase | Scope | Depends on | Wave |
|---|---|---|---|
| R1 Tokens & fonts | Colour sets, tints, label palette, radius/motion/typography tokens, bundled fonts (download official OFL releases: github.com/adobe-fonts/source-serif, github.com/vercel/geist-font; include OFL.txt), `MailTheme.Web` palette + reading font. Swap existing views to the new tokens WITHOUT changing layout/behaviour. | — | 1 |
| R2 Domain model & prefs | Pure, additive: `MailDomain` derivation from `[Mailbox]`, `DomainMonogram` (2 letters; 3 on clash in one account; override wins), `DomainPreferences` (UserDefaults `domain.<accountID>.<domainID>.{monogram,includeInAll,countInBadge,notify,hidden,hiddenAt}`), `AccountTint` assignment (FNV-1a via `MailboxColorAssignment` logic keyed on account id + override `account.<accountID>.tint`), `ListDensity` pref `list.density`. Unit tests. No UI. | — | 1 |
| R3a Scope/folder/label state | Replace `FolderSelection`+`SidebarItem` with independent `scope` (`.allDomains/.domain/.mailbox`), `folder` (5 conversation folders + drafts), `label`. Store scope queries `String?` → `Set<String>?`. `.allDomains` honours hidden/includeInAll. Label listing = folder ∩ label. Drafts by scope (`.allDomains` includes nil mailbox). Domain search = all-mailbox server search filtered client-side. Persist per account + one-time migration of `sidebar.mailbox.<accountID>`. Minimal view adapters only so the app still builds and works. | R2 | 2 |
| R3b Per-domain effects | Domain/mailbox unread aggregation (Inbox, N6), label counts per folder (`LabelIndex`), Dock badge honours countInBadge/hidden, notifier honours notify/hidden, remove per-mailbox colour model (`mailboxPalette`, `mailboxColorOverrides`, row chip colouring → account tint) + one-time purge of `mailboxColor.*`. | R3a | 3 |
| R4 Sidebar | Account card + popover (replaces AccountSwitcher + ellipsis menu), 3 drill levels on `List(.sidebar)`, labels at level 1, filter fields, domain context menu (Open / Mark All as Read / Domain Settings… / Hide), gear, scope motion, a11y ids + UI-test page objects. | R1, R3b | 4 |
| R5 List column + thread | Toolbar search prompt per scope, header band w/ folder menu (L1–2) / plain title (L3), caption + label chip ×, row rebuild (attribution rule, badges, density, "No mailbox" draft tag), empty states, thread header/back/"N messages · M people"/own-message tint avatar. | R1, R3b | 4 |
| R6 Reading pane | Serif subject, "Message N of M", sender block + To/From chip w/ badge, toolbar order + primary New, body 14/1.6 via CSS vars, "Nothing selected". | R1, R2 | 2 |
| R7 Settings shell + root pages | Split-view Settings (drill-down sidebar + detail), settings route in AppEnvironment (deep-link: Account, Domain), General (Density + previews), Notifications/Privacy/Signatures moved in, Account page (server, sync + Sync Now, colour + Reset, Sign Out… w/ confirm; copy per N1/N2). Removes MailboxSettingsPane VIEW + tab. | R1, R2 | 2 |
| R8 Domain settings pages | Domain level: Overview (name, mailbox count, monogram field, 3 toggles), Mailboxes table, Signatures (domain-filtered existing model), Workflows disabled. | R7, R3b | 5 |
| R9 Hide domain | Remove-domain page: Hide Domain, Hidden domains list w/ Restore, Open in HQBase Admin ↗ (origin root, N5); sidebar context-menu Hide wired; hidden domains vanish from sidebar/counts/badge/notifications. | R4, R8 | 6 |
| A1–A4 Audits | A1 per-phase review vs plan (orchestrator), A2 memory audit, A3 fresh-eyes audit of landed work, A4 whole-touched-surface audit → proposals. | all | 7 |

Orchestrator merges each finished phase into `redesign` (no fast-forward), runs the full unit suites after each merge, and runs the UI suite serially at the end of waves 4–6 (UI runs kill same-bundle-id instances, so sub-agents never run it).

---

## SUB-AGENT BRIEF (every phase agent follows this)

**Setup**
1. You are in a git worktree of `/Users/awizemann/Developer/hqbase-mac` based on the `redesign` branch. The design folder and managed tiers are NOT reliable in your worktree — read design from the absolute path above; read memory ONLY through the `memophant` MCP tools (never grep `.memory/` in the worktree — it is a stale snapshot).
2. `read_charter` (commandments are absolute). Read `CLAUDE.md` and `AGENTS.md` in the worktree. Use `build_context` / `search_memories` for the notes relevant to your phase — at minimum: "Herald Architecture", "Herald Concurrency Rules", "Herald Design System and Accessibility", "Herald Testing Conventions", "Herald Build and Toolchain"; plus labels/drafts/sync notes where relevant.
3. `get_task` your task id, then `move_task(id, "doing")`. Do NOT move it to done — the orchestrator does after review.

**Rules**
- Charter C1–C6. Views/view-models consume Sendable DTOs only; `@Model` stays in `MailStore`. Default-MainActor stays on.
- New UI reads `MailTheme` tokens; no raw spacing/radius/colour/font literals where a token fits. Reduce-motion gated at the call site. Every colour cue paired with text/shape; VoiceOver labels on new controls; hit targets ≥ 28pt.
- Match surrounding code style (comment density, naming). Don't over-engineer; reuse before adding.
- Stay in your phase's scope. Something broken outside it → report it, don't fix it.
- Don't commit managed tiers (`.memory/ wiki/ design/ code/ sessions/ documents/ vendors/ templates/ TASKS.md tasks/`). Never push.

**Build & test** (in your worktree root)
- `xcodegen generate` (needed after adding files; project is gitignored).
- Build+unit tests: `xcodebuild test -project Herald.xcodeproj -scheme Herald -destination 'platform=macOS' -derivedDataPath ./DerivedData -skipPackagePluginValidation -only-testing:HeraldTests 2>&1 | tail -40` (runner-hang message = flake, rerun once).
- HeraldKit: `cd HeraldKit && swift test` then `git checkout HeraldKit/Package.resolved`.
- UI test target must still COMPILE (`xcodebuild build-for-testing … `) if you touched accessibility ids or page objects — but NEVER run the UI suite (`scripts/ui-tests.sh`); the orchestrator runs it serially.
- Do not run `scripts/build-detached.sh` (it launches/kills the shared dev app).

**Cycle** — plan → implement → test for real (discriminating Swift Testing tests that would fail on the old behaviour; exercise the function, not just the diff; full HeraldTests green) → fresh-eyes adversarial self-audit of your whole diff INCLUDING tests (no checkbox tests; look for concurrency, a11y, token misuse, dead code, stale comments) and fix what you find → commit on your worktree branch (conventional message, body explains why, end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` — or your own model name).

**Memory** — record durable facts via memophant: architecture/decision changes, recurring issues, gotchas. `search_memories` first; `edit_memory` an existing note rather than forking; pass `source_paths`; file under the six folders. Correct any memory your change makes stale. Keep it lean — no changelog-style notes.

**Final report** (your last message, plain English, concise): worktree branch name + commit SHAs; what was built vs the plan (and any deviation + why); files touched; tests run with exact pass/fail counts; self-audit findings and what you fixed; memories created/edited (permalinks); open questions / follow-ups for the orchestrator.
