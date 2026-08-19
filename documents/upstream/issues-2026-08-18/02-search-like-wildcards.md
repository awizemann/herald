Title: Mail API: `search` treats `%` and `_` in the user's term as LIKE wildcards

Small bug, two call sites.

`GET /api/v1/messages` builds its search predicate at `worker/features/messages/queries.ts:168-173`:

```ts
if (filters.search) {
  where.push("(subject LIKE ? OR from_address LIKE ? OR to_json LIKE ? OR snippet LIKE ? OR text_body LIKE ?)");
  const like = `%${filters.search}%`;
  params.push(like, like, like, like, like);
}
```

`GET /api/v1/conversations` does the same at `worker/features/messages/conversation-queries.ts:62-68`.

The term is interpolated straight into the pattern, so SQLite's LIKE metacharacters survive: searching `100%` matches every message (the `%` is "any run of characters"), `a_b` matches `axb`, and a user searching for a literal `_` in a filename or an address local part gets noise. It's a correctness/UX bug, not an injection — binding is parameterized — but it's the kind that looks like the search is broken.

**Fix.** Escape the three metacharacters and declare the escape character:

```ts
const like = `%${filters.search.replace(/[\\%_]/g, "\\$&")}%`;
```

and append `ESCAPE '\'` to each `LIKE ?` in both predicates. Backslash first in the character class so escapes aren't double-processed.

Motivation: Herald (native macOS client) is about to route its search box to `GET /conversations?search=`; today a term with `%` silently returns the whole folder, which reads as a client bug.

Happy to PR it — one helper shared by both query builders plus unit tests that `100%` matches only messages containing `100%`, that `a_b` doesn't match `axb`, and that a literal backslash is still findable. No spec change needed, though the `search` parameter description could gain "wildcards are matched literally".
