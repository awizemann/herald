# Upstream issue drafts — HQBase/hqbase, 2026-08-18

Six drafted issues from the Herald feature investigation (`documents/reports/feature-investigation-2026-08-18.md`).
**Nothing has been filed.** Every claim below was verified against upstream `main` @ `8670c66e752e4f709c042ccaf24f9a83e913638b`
(fetched via raw.githubusercontent.com / `gh api`, not the local `~/Developer/hqbase` checkout, which is behind).

Each file's **first line is `Title: …`** and is not part of the body. The commands below strip it with `tail -n +2`
(zsh/bash process substitution), so run them from this directory.

| # | File | Kind | Verified on main |
|---|------|------|------------------|
| 01 | `01-draft-attachment-content-type.md` | small spec fix | yes — spec declares no `encoding`/`contentType`; server *does* honor `file.type` |
| 02 | `02-search-like-wildcards.md` | small bug | yes — `%`/`_` unescaped at both call sites |
| 03 | `03-fts5-search.md` | design discussion | yes — no FTS anywhere in the repo |
| 04 | `04-changes-stream.md` | design discussion | yes — `/changes` is poll-only, push is browser Web Push only |
| 05 | `05-drafts-sync.md` | design + small fix | yes — journal is messages-only, `GET /drafts` unpaged, `drafts` folder unreachable |
| 06 | `06-forward-route.md` | small feature | yes — `forwardMessage` exists but is MCP-only |

## Commands

```sh
cd documents/upstream/issues-2026-08-18

gh issue create -R HQBase/hqbase \
  --title "Mail API: draft attachment uploads lose their MIME type because the spec declares no per-part Content-Type" \
  --body-file <(tail -n +2 01-draft-attachment-content-type.md)

gh issue create -R HQBase/hqbase \
  --title "Mail API: \`search\` treats \`%\` and \`_\` in the user's term as LIKE wildcards" \
  --body-file <(tail -n +2 02-search-like-wildcards.md)

gh issue create -R HQBase/hqbase \
  --title "Search design: back \`search=\` with an FTS5 index instead of five unanchored LIKEs" \
  --body-file <(tail -n +2 03-fts5-search.md)

gh issue create -R HQBase/hqbase \
  --title "Mail API: a streaming \`GET /api/v1/changes/stream\` (SSE or long-poll) so native clients don't have to poll" \
  --body-file <(tail -n +2 04-changes-stream.md)

gh issue create -R HQBase/hqbase \
  --title "Mail API: drafts have no delta path (not in the changes journal, \`GET /drafts\` unpaged), and the \`drafts\` message folder is dead" \
  --body-file <(tail -n +2 05-drafts-sync.md)

gh issue create -R HQBase/hqbase \
  --title "Mail API: expose forward on \`/api/v1\` — the implementation exists but only MCP can reach it" \
  --body-file <(tail -n +2 06-forward-route.md)
```

## Suggested order

File the two small ones first (02, 01), then 06, then the three design issues (05, 04, 03) — the
pattern that has worked so far with @bermanto is small verifiable fixes first, design discussion
with an explicit offer to implement second.

## Duplicate check

Checked `gh issue list --state all` and `gh pr list --state all` on 2026-08-18: none of these six are
already filed. Adjacent open threads for cross-reference: #41 (refresh-token reuse interval),
#42 (restore from Trash), #32 (Herald adoption), #37 (changes feed, merged — 04 and 05 build on it),
#35 (messages pagination, merged — 03 and 05 reuse its cursor pattern).
