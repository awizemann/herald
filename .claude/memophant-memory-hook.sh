#!/usr/bin/env bash
# Memophant memory hook (managed by Memophant) — regenerated; do not edit by hand.
# Surfaces this repo's memory at session start, agent-agnostic: invoked by Claude Code
# via .claude/settings.json, by Codex via .codex/hooks.json, and by Gemini CLI via
# .gemini/settings.json — the script self-locates via BASH_SOURCE, so the env-var
# fallback is only used if that fails. CLAUDE_PROJECT_DIR / CODEX_PROJECT_DIR /
# GEMINI_PROJECT_DIR are tried in order.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
[ -z "$ROOT" ] && ROOT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-${GEMINI_PROJECT_DIR:-.}}}"
# Git worktrees don't carry the gitignored .memophant/mcp/ binary, so this checkout's tracked
# .mcp.json (command ./.memophant/mcp/memophant-mcp) points at a missing
# file and the memophant MCP server can't launch there. Self-heal silently: if the binary is
# absent and we're in a linked worktree, symlink it from the main worktree (the shared
# --git-common-dir's parent). Gated on the binary being missing, so the normal checkout pays
# nothing. The symlink lands in the gitignored .memophant/ so it's never committed.
MCP_BIN="$ROOT/.memophant/mcp/memophant-mcp"
if [ ! -x "$MCP_BIN" ]; then
  common="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null)"
  if [ -n "$common" ]; then
    case "$common" in /*) ;; *) common="$ROOT/$common" ;; esac
    main_root="$(cd "$common/.." 2>/dev/null && pwd)"
    main_bin="$main_root/.memophant/mcp/memophant-mcp"
    if [ -n "$main_root" ] && [ -x "$main_bin" ] && [ "$main_bin" != "$MCP_BIN" ]; then
      mkdir -p "$ROOT/.memophant/mcp" 2>/dev/null && ln -sf "$main_bin" "$MCP_BIN" 2>/dev/null
    fi
  fi
fi
HEALTH_FILE="$ROOT/.memophant/mcp/health.json"
# Memophant "active" indicator — a cheap, worktree-safe liveness PROXY computed at session
# start. The hook runs BEFORE this session's MCP connection, so it confirms the PIECES are in
# place (the binary is present + memophant is registered + this repo has a .memory/ tier), not
# that the model has connected. Emitted FIRST so the agent leads with "tools available"; the
# operator's custom instructions follow. tool_count is enriched from health.json when present
# (the app writes it on the main checkout; it's gitignored, so absent in worktrees — the line
# still shows, just without the count).
# Match the SERVER-REGISTRATION key `"memophant":` (object key → trailing colon, optional space
# before it as Foundation's pretty-printer emits) — NOT the bare `"memophant"` that also appears
# as the `--default-project` arg VALUE in the args array (no colon), which would false-positive.
MEMO_REGISTERED=""
if [ -f "$ROOT/.mcp.json" ] && grep -Eq '"memophant"[[:space:]]*:' "$ROOT/.mcp.json" 2>/dev/null; then MEMO_REGISTERED="yes"; fi
if [ -z "$MEMO_REGISTERED" ] && [ -f "$HOME/.claude.json" ] && grep -Eq '"memophant"[[:space:]]*:' "$HOME/.claude.json" 2>/dev/null; then MEMO_REGISTERED="yes"; fi
if [ -x "$MCP_BIN" ] && [ -d "$ROOT/.memory" ] && [ -n "$MEMO_REGISTERED" ]; then
  active_tools=$(grep -o '"tool_count"[[:space:]]*:[[:space:]]*[0-9]*' "$HEALTH_FILE" 2>/dev/null | grep -o '[0-9]*' | head -n 1)
  echo "## Memophant MCP Tools and Memory Active${active_tools:+ — ${active_tools} tools}"
  echo ''
fi
PROMPT_FILE="$HOME/Library/Application Support/Memophant/session-prompt.txt"
if [ -s "$PROMPT_FILE" ]; then
  echo '## Operator instructions (set in Memophant → Settings — applies to every session)'
  cat "$PROMPT_FILE"
  echo ''
fi
echo '## Repo memory (managed by Memophant) — the single source of truth'
echo 'Search the repo memory before assuming; record durable decisions/learnings as memory notes (write_memory) or wiki pages — never in session-private memory. Search before writing and edit the existing note (edit_memory) rather than forking a near-duplicate. File every note under ONE of the six folders (architecture/conventions/decisions/operations/project/roadmap); when a note is grounded in code, pass source_paths so Memory Health can drift-check it — an unanchored code note cannot be kept current.'
echo 'PREFER the `memophant` MCP tools for everything they cover (search_memories, read_memory, write_memory, edit_memory, build_context, tasks, tier files, and more) — they carry the guards (slug-gen, validation, secret scan). Found or made a credential → store it with set_vendor_credential, never in chat. Server down → grep .memory/ and wiki/.'
if [ -d "$ROOT/.memory" ]; then
  echo ''
  total=$(find "$ROOT/.memory" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  if [ "${total:-0}" -le 30 ]; then
    echo 'Available .memory notes:'
    find "$ROOT/.memory" -type f -name '*.md' 2>/dev/null | sed "s#^$ROOT/.memory/##" | sort | while IFS= read -r n; do echo "- $n"; done
  else
    echo "Memory: $total notes (index bounded to save context). Areas:"
    find "$ROOT/.memory" -type f -name '*.md' 2>/dev/null | sed "s#^$ROOT/.memory/##" | sed 's#/.*##' | sort | uniq -c | while read -r c d; do echo "- $d ($c)"; done
    echo 'Most recently updated:'
    git -C "$ROOT" log -n 80 --diff-filter=ACMRT --name-only --pretty=format: -- "$ROOT/.memory" 2>/dev/null | grep '\.md$' | sed 's#^.*\.memory/##' | awk 'NF && !seen[$0]++' | head -n 10 | while IFS= read -r n; do echo "- $n"; done
    echo 'Search the rest via the `memophant` MCP server (search_memories "<query>") or: find .memory -name "*.md".'
  fi
fi
if [ -d "$ROOT/wiki" ]; then
  echo ''
  echo 'Wiki present (wiki/): search the `hqbase-mac-wiki` project via the memophant MCP server, or grep wiki/.'
fi
if [ -d "$ROOT/design" ]; then
  echo ''
  echo 'Design tier present (design/): consult before UI work — search the `hqbase-mac-design` project via the memophant MCP server, or grep design/.'
fi
if [ -d "$ROOT/documents" ]; then
  echo ''
  echo 'Documents tier present (documents/ — exact lowercase at the repo root): save agent-generated artifacts (plans/reports/briefs) there via write_tier_file(tier:"documents", path:...) — NEVER in a docs/ folder (docs/ is hand-authored documentation the project owns) and never a case-variant like Documents/.'
fi
if [ -f "$ROOT/TASKS.md" ]; then
  echo ''
  echo 'Task board (TASKS.md): read it. Prefer the memophant MCP task tools — create_task / move_task(id,status) / update_task / list_tasks — which own the (id:) board line + tasks/<id>.md atomically (no orphans). Fallback (server down): hand-edit TASKS.md, moving a line between ## Todo/Doing/Done (status = its section; Memophant mirrors the tasks/<id>.md status:). Add tasks you discover.'
  open_items=$(grep -c '^- \[ \]' "$ROOT/TASKS.md" 2>/dev/null)
  echo "Open checklist items: ${open_items:-0}"
fi
# MCP server status — populated by Memophant.app's health check (passive on project
# open, active via the "Recheck" button on the memory dashboard). Lets a Claude session
# know up front whether the native memophant tools are usable. When the server is down
# the fallback is grep over .memory/ and wiki/ directly — basic-memory has been retired
# from production as of 2026-06-06; see wiki/Memory-Engine-Test-Suite.md if you need to
# re-enable it for regression testing.
if [ -f "$HEALTH_FILE" ]; then
  echo ''
  if grep -q '"status"[[:space:]]*:[[:space:]]*"ready"' "$HEALTH_FILE" 2>/dev/null; then
    tools=$(grep -o '"tool_count"[[:space:]]*:[[:space:]]*[0-9]*' "$HEALTH_FILE" | grep -o '[0-9]*' | head -n 1)
    echo "MCP server: ✓ memophant (${tools:-?} tools) — review what each does before you start, and prefer them over ad-hoc file ops."
  else
    reason=$(grep -o '"reason"[[:space:]]*:[[:space:]]*"[^"]*"' "$HEALTH_FILE" | sed 's/.*"\([^"]*\)"$/\1/' | head -n 1)
    echo "MCP server: ✗ memophant${reason:+ — $reason}"
    echo "  → open Memophant.app to reinstall, or grep .memory/ + wiki/ directly until the server is back."
  fi
fi
exit 0