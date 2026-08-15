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

# Herald — native macOS client for HQBase

Read `.memory/` first (project overview, architecture, conventions). Non-negotiables:
- Swift 6.2 approachable concurrency: `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`, strict concurrency. See "Herald Concurrency Rules".
- Strict Sendable DTO boundary; views never touch @Model. See "Herald Architecture".
- SwiftData store is a rebuildable cache — server is the system of record. See "Herald Sync Model".
- Swift Testing, discriminating tests, URLProtocol fake server. See "Herald Testing Conventions".
- `project.yml` is source of truth; `xcodegen generate`; build with `./scripts/build-detached.sh`.
- Never push to the remote without explicit approval.
