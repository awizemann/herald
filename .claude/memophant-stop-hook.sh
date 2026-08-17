#!/usr/bin/env bash
# Memophant stop hook (managed by Memophant) — regenerated; do not edit by hand.
# Records a one-line activity entry when a Claude session stops (machine-local log).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
[ -z "$ROOT" ] && ROOT="${CLAUDE_PROJECT_DIR:-.}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LOG="$ROOT/.claude/memophant-activity.log"
echo "$TS session stopped" >> "$LOG" 2>/dev/null
exit 0