# Herald redesign v3 — audit + compose/attachments plan (2026-09-28)

Spec: `design/design_handoff_herald_redesign 3/` (README.md is authoritative; v3 = v2 + §3.3 Compose + reading-pane Attachments). v1/v2 folders deleted at the end (V7).

Decisions (Alan, 2026-09-28): fix findings in-run (judgment calls come back to Alan); commit directly on main (each agent commits only its own paths, never managed tiers); visual audit runs the app against the local HQBase test instance (see memory `operations/hqbase-local-test-instance-v1-4-2`).

## Spike conclusions (2026-09-28)
- Recipient tokens: **pure SwiftUI** (custom `Layout` flow + trailing TextField), NOT NSTokenField (public API can't draw avatar or per-token danger style). Binding stays `toText/ccText/bccText` strings → draft save/idempotency untouched. Commit on comma/Return/Tab/focus-loss; Delete on empty selects then removes last token; paste splits; per-token VoiceOver label + Remove action. Display name only when known, else address.
- From: `MailboxAddress.sendEnabled` already mapped (spec calls it canSend). Custom popover (340w, filter, grouped by domain, disabled rows). Reply From must match original To/Cc against sendable addresses (today uses mailbox primary — spec violation). Changing From must also set `draft.mailboxID`; a hand-picked signature not valid for the new address resets to automatic.
- Attachments: reading pane has Quick Look + Download already (chip). Download All = folder chooser (NSOpenPanel, directories) + loop `AttachmentFile.url` → copy. Compose attachments have no GET: keep id→local URL map for files added this window session (hold security scope, clean up); hide Quick Look/Download for attachments without a local copy (reopened drafts). Upstream question queued: can `GET /attachments/{id}` serve draft attachment ids?
- Window: compose is `WindowGroup(for: ComposeRequest.ID)`. 52pt band via empty unified NSToolbar (traffic lights centred) + SwiftUI band content; default/min 820×620; keep `.navigationTitle` for Window menu; verify ⌘↩/⌘W/paste shortcuts survive.

## Phases (sequential unless noted — all on main)
- **V1 Tokens & identity audit+fix** — MailTheme, asset colours (light/dark/Increase Contrast), 8 tints + avatar text, 10 label colours, wash recipes, badge letters/clash rule, radii, hit targets, Reduce Motion gating, SF Symbol map (§1, §2, §5). Raw-literal sweep in Views/Settings/Compose.
- **V2 Main window visual audit+fix** (parallel with V3; files: Herald/Views/**, sidebar/list/thread/reading pane minus attachments) — live app vs screenshots 2a-*, 3a-*, 4a-0, 5a-*, light/dark, Comfortable/Compact.
- **V3 Settings visual audit+fix** (parallel with V2; files: Settings views only) — screenshots 4a-1..4, 5b-*.
- **V4 Attachment cards** — new `AttachmentCard` replacing `AttachmentChip` (reading pane + compose), Download All, compose Remove, local-URL map for compose Quick Look/Download.
- **V5 Compose model** — From candidates (grouped, filter, sendEnabled), reply-address matching, mailboxID sync, signature reset on From change, `showsCcBcc` rules (reply-all / draft has cc/bcc), footer validation message, Send-enabled rule (≥1 valid recipient), signature scope caption. Tests.
- **V6 Compose window UI** — 52pt band, header grid (64|1fr), From field+popover, token field, Subject serif 18, body inset 98 / max 600, signature block, footer with signature picker + validation. Live visual check vs 6a-*.
- **V7 Orchestrator close** — audit against plan, memory audit (dedupe/validate), delete design v1+v2 folders, fresh-eyes audit of all V1–V6 commits.

Each sub-agent: implement → build (`./scripts/build-detached.sh`) → run tests → exercise the real feature → own fresh-eyes audit (tests included, no checkbox tests) → commit own paths → record durable learnings via memophant (edit existing notes first) → report findings with file:line.
