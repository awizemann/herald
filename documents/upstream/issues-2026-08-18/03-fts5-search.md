Title: Search design: back `search=` with an FTS5 index instead of five unanchored LIKEs

Discussion/design issue — I'd like to agree the shape before writing code, and I'm offering to implement it.

## Today

Both search paths are five `LIKE '%term%'` predicates over the messages table:

- `worker/features/messages/queries.ts:168-173` — `subject`, `from_address`, `to_json`, `snippet`, `text_body`, inside the same `WHERE` as the folder/mailbox filters, ordered by the keyset activity expression (`:183-184`).
- `worker/features/messages/conversation-queries.ts:62-68` — the same five columns in the `eligible_threads` CTE of the conversation query.

Because the pattern is leading-`%`, no index can serve it: every search is a full scan of `messages` including `text_body`, which is the largest column in the table. That's fine at a few thousand messages and gets slow on D1 exactly when a mailbox becomes worth searching. It also gives substring semantics rather than word semantics (`ann` matches `channel`), no ranking, no phrase or prefix queries, and no way to score a subject hit above a body hit.

Motivation: Herald is a native macOS client that keeps a local cache and is wiring its search box to `GET /conversations?search=`. A remote search that costs a full table scan per keystroke-debounce isn't something a client can lean on, so today it falls back to filtering its local cache — which can only ever search what it has already synced.

## Proposal

**Table.** An external-content FTS5 table so the text isn't stored twice:

```sql
CREATE VIRTUAL TABLE messages_fts USING fts5(
  subject, from_address, recipients, snippet, text_body,
  content = 'messages',
  content_rowid = 'rowid',
  tokenize = 'unicode61 remove_diacritics 2'
);
```

`recipients` is `to_json` (plus `cc_json`, arguably) — worth flattening the JSON to a space-joined address list in the trigger rather than indexing the raw JSON, so punctuation doesn't pollute the token stream. `unicode61` keeps it dependency-free; `porter` on top is an option if stemming is wanted, but it hurts address matching.

**Triggers.** External-content FTS5 needs the standard three, mirroring `migrations/0013_message_changes.sql`'s pattern:

```sql
CREATE TRIGGER messages_fts_ai AFTER INSERT ON messages BEGIN
  INSERT INTO messages_fts(rowid, subject, from_address, recipients, snippet, text_body)
  VALUES (NEW.rowid, NEW.subject, NEW.from_address, NEW.to_json, NEW.snippet, NEW.text_body);
END;
CREATE TRIGGER messages_fts_ad AFTER DELETE ON messages BEGIN
  INSERT INTO messages_fts(messages_fts, rowid, ...) VALUES ('delete', OLD.rowid, ...);
END;
CREATE TRIGGER messages_fts_au AFTER UPDATE ON messages BEGIN ... 'delete' then insert ... END;
```

The update trigger fires on every state change (read/star/archive), which is a wasted reindex of `text_body`; `AFTER UPDATE OF subject, snippet, text_body, from_address, to_json` narrows it to the columns that matter. Worth flagging because message state changes are the hot write path.

**Backfill.** Migration `0014` creates the table, runs `INSERT INTO messages_fts(messages_fts) VALUES('rebuild')`, creates the triggers, then `PRAGMA optimize` (same lesson as #35 — D1's planner has no `sqlite_stat1` for a brand-new index). `rebuild` on an existing large mailbox is one statement; if that's too big for a single D1 migration on real deployments, the alternative is a nullable `fts_indexed_at` and a lazy backfill, but I'd start with `rebuild` and measure.

**Query, and compatibility with cursor pagination.** This is the part I most want your read on. The safe shape keeps FTS5 as a *filter only* and leaves ordering untouched:

```sql
messages.rowid IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?)
```

dropped in where the five LIKEs are today, in both query builders. Ordering stays `activity_at DESC, id DESC`, so the existing `m1`/conversation cursors keep working unchanged, `Link: rel="next"` is unaffected, and no cursor version bump is needed. Relevance ranking (`bm25(messages_fts, 10.0, 4.0, 4.0, 2.0, 1.0)` — weighting subject and addresses above body) would need a *different* cursor encoding (score is not stable across index churn), so I'd propose deferring it, or exposing it later as an explicit `sort=relevance` that returns an offset-style cursor and is documented as best-effort.

**User query syntax.** Raw user input can't go into `MATCH` — `AND`, `*`, `"` and `-` are operators and a stray one is a 400 from SQLite. Proposal: tokenize the input server-side and rebuild a safe query — each token double-quoted, joined with `AND`, last token given a trailing `*` for prefix-as-you-type. That keeps `search=` semantics compatible-ish with today for normal terms while dropping substring-in-the-middle matching (`ann` no longer matches `channel`); that behavior change is the one thing worth calling out in the spec description. An explicit advanced syntax could come later behind a separate parameter.

**Not covered, but adjacent:** attachment filenames aren't searchable at all today, and `search` is always scoped to one folder. Both get cheap once there's an FTS table (a second `attachments_fts`, and simply allowing `search` without `folder`). Happy to keep them out of scope.

**Tests.** Unit tests for the query builder (safe `MATCH` construction from hostile input), an integration test that search results are identical to the LIKE implementation for plain single-word terms, one for pagination across a search result set with the existing cursor, and an `EXPLAIN QUERY PLAN` assertion that the virtual table is used rather than a scan — same discriminating-plan-test pattern as #35.

Happy to implement all of it, spec change in hqbase-site first as usual. Two questions before I start: (1) filter-only, or do you want relevance ranking in the first pass? (2) is a `rebuild` backfill acceptable in a migration for your largest known deployment?
