<!-- memophant:begin -->
<!-- memophant:shim -->
## Memory System (managed by Memophant) — core rules. Full reference: [AGENTS.md](./AGENTS.md).
1. **Memory is the source of truth.** Search it before assuming; record durable decisions/learnings as memory notes or wiki pages — never in this file or session-private/model memory. Search before writing and edit an existing note (`edit_memory`) rather than forking a near-duplicate.
2. **Prefer the `memophant` MCP tools** for every read/write (search/read/write/edit/move) — read each tool's description (they document their args). The engine is the gate: the tool/app entry points carry the guards (slug-gen, structure validation, write-time secret scan); direct edits reconcile automatically but skip them — never compose your own guard set. Tools absent → grep `.memory/` + `wiki/`.
3. **Don't `git add`/`commit` the managed tiers** (`.memory/`, `wiki/`, `design/`, `code/`, `sessions/`, `documents/`, `vendors/`, `templates/`, `TASKS.md`, `tasks/`) — the user commits each via Memophant's per-tier secret-scanned bar; leave them dirty. Everything else is yours.
4. **Secrets → Keychain, never chat or files.** Found or made a credential? Store it with `set_vendor_credential` (fetch later with `get_vendor_credential`); never leave it loose in chat.
5. **Agent artifacts (plans/reports/briefs) → `documents/` (exact lowercase), via `write_tier_file(tier: "documents", path: …)`** — never a repo's `docs/` folder (that's the project's own documentation) and never a case-variant like `Documents/`.
File memory notes under one of six folders (architecture/conventions/decisions/operations/project/roadmap), never the root. When a note is grounded in code, pass `source_paths` (the repo files it depends on) so Memory Health can drift-check it — an unanchored code note can't be kept current.
<!-- memophant:end -->

## Standards
This project follows the centralized standards at `/Users/awizemann/Developer/_standards/` (read `INDEX.md` first). Where Herald deliberately diverges — do NOT "fix" these, they are load-bearing:
- **SwiftData store is a rebuildable cache** (server is system of record): bare `Schema([...])`, NO `VersionedSchema`/`SchemaMigrationPlan`, no backup/restore parity, no `NSFileCoordinator` (non-iCloud app). Recovery = delete + re-sync. See "Herald Sync Model".
- **Loggers** are file-scope `private nonisolated let logger` (not the standard's in-type decl) under Swift 6.2 default-MainActor; subsystem is the bundle id `com.wizemann.herald` (Apple-idiomatic, not `com.<app>.app`). See "Herald Concurrency Rules".
- **Design tokens** are `MailTheme` — status colors, mailbox palette, chip/selection surfaces, and the spacing/radius/typography/animation scales (`MailTheme.Spacing/Radius/Typography/Animation`, `unreadDotDiameter`). New UI reads from the tokens; no raw spacing/padding/radius/font-size literals where one fits. See "Herald Design System and Accessibility".
- Standards 06 (tabbed editor), 07 (AI), 11 (multiplatform) are N/A — Herald is a macOS-only mail-triage client with no AI.

Full audit record (2026-08-18): report `documents/reports/standards-audit-2026-08-18.md`, memory note `operations/Standards Audit 2026-08-18`. All four remediation tasks landed 2026-08-18 (commits 5526423 hygiene, 8282ffb design tokens, 9df695d os_unfair_lock, f7ef9a5 file split) — see the memory note for the closing summary.

# Herald — native macOS client for HQBase

Read `.memory/` first (project overview, architecture, conventions). Non-negotiables:
- Swift 6.2 approachable concurrency: `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`, strict concurrency. See "Herald Concurrency Rules".
- Strict Sendable DTO boundary; views never touch @Model. See "Herald Architecture".
- SwiftData store is a rebuildable cache — server is the system of record. See "Herald Sync Model".
- Swift Testing, discriminating tests, URLProtocol fake server. See "Herald Testing Conventions".
- `project.yml` is source of truth; `xcodegen generate`; build with `./scripts/build-detached.sh`.
- Never push to the remote without explicit approval.
