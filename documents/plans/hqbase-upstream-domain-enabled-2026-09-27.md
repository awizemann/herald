# HQBase upstream: `domainEnabled` on v1 mailbox addresses (drafts)

Status: DRAFT. Not filed, not pushed. Target repository: `HQBase/hqbase` (remote `upstream`).

- Branch: `feat/v1-mailbox-address-domain-enabled`, two commits on top of `upstream/main` (a1161f1, 1.4.2): 4f7f431 and 3f75bf3.
- Patch: `/private/tmp/claude-501/-Users-awizemann-Developer-hqbase-mac/dceff1ae-dd08-4b74-9219-d1aae53d2002/scratchpad/hqbase-domain-enabled.patch`
- Before filing: the HQBase AGENTS.md asks for the canonical spec in `hqbase-site/src/content/docs/docs/specs/` to change first. That repo is not checked out here. Open a matching `hqbase-site` change, or ask the maintainers where the v1 mailbox spec lives.

---

## Issue draft

**Title:** v1 Mail API: show when a mailbox address's domain is turned off

**Body:**

### Problem

An owner can turn off an email domain on the Domains page, or disconnect it. HQBase then stops
receiving and sending mail for every mailbox on that domain.

A client of the v1 Mail API cannot see this. `GET /api/v1/mailboxes` returns each mailbox with an
`addresses` list. Each address has `mailDomainId`, but nothing tells the client whether that domain
is active. The mailbox itself still shows `isActive: true`, `receiveEnabled: true`, and
`sendEnabled: true`.

The result: native clients (for example, the Herald macOS client) keep showing mailboxes on a
turned-off domain as normal. The user can pick one as a sender, and the send then fails on the
server.

### Why the admin API does not help

The domain switch lives in the admin API (`GET/PATCH /api/domains`). The v1 OpenAPI document says:
"Administrative APIs are not part of this contract." The admin API uses a browser session cookie
and owner or admin role. A v1 client uses an OAuth token with `mail:*` scopes and cannot call it.
Members cannot call it at all. So v1 clients have no supported way to learn the domain state.

### Proposal

Add one boolean to each v1 `MailboxAddress`:

```json
{
  "id": "mbx_…",
  "mailboxId": "mbx_…",
  "mailDomainId": "dom_…",
  "address": "team@example.com",
  "displayName": "Team",
  "receiveEnabled": true,
  "sendEnabled": true,
  "isPrimary": true,
  "domainEnabled": false
}
```

`domainEnabled` is the value of `mail_domains.is_enabled` for the address's domain. It is `false`
when the owner turns the domain off, and also when the owner disconnects the domain (disconnect sets
`is_enabled = 0`).

### Compatibility

- The v1 document says additive fields may be added within v1 and clients must ignore unknown
  response fields. This is one new field. No field changes or goes away.
- v2, the MCP tools, and the admin `/api/mailboxes` list stay unchanged.
- The server already checks `is_enabled = 1` before it delivers or sends mail, so the new field
  only exposes a state the server already enforces.

### Open question

v2 `Mailbox` has the same gap (it has `mailDomainId` but no domain state). I kept this change to v1
because that is what our client uses today. I can add the same field to v2 in this change or in a
follow-up if you prefer.

---

## Pull request draft

**Title:** Show domain state on v1 mailbox addresses

**Body:**

### Summary

v1 clients cannot tell when an owner turns off or disconnects an email domain. This change adds a
`domainEnabled` boolean to each v1 `MailboxAddress`. It closes #<issue>.

### Changes

- `worker/features/mailboxes/routes.ts`: on the `/api/v1` path only, read the enabled domain IDs
  with the existing `listMailDomains` query and set `domainEnabled` on each address. v2 and the
  admin mailbox list use the same handler but take the unchanged path.
- `api/hqbase-mail-api-v1.openapi.json`: add `domainEnabled` (boolean, required) to
  `MailboxAddress`, with a description. `pnpm api:generate` shows no Postman change, because the
  collection has no response examples for mailboxes.
- `CHANGELOG.md`: add an entry under a new "Unreleased" section. It says that earlier versions
  do not send the field.

No schema change and no migration. The domain state comes from a second small query on the v1
path, not from a join. A join would change `listMailboxesForUser`, which v2, MCP, and the admin
mailbox list also use. The MCP `list_mailboxes` tool returns the v2 mailbox shape, so it
does not change. The admin UI `Mailbox` type does not use `MailboxAddress`, so it does not change.

### Why the field is required

The server always sends the field, so the schema marks it as required, like other v1 response
fields such as `fromName`. This tells generated clients that they can read it as a plain boolean.
Each HQBase installation serves its own `/api/v1/openapi.json`, so an older installation still
serves an older document without the field. HQBase versions before this change do not send
`domainEnabled`. A client that supports those versions should treat a missing value as `true`. The
changelog entry says this; the schema description does not, so it does not contradict `required`.

### Tests

- `test/integration/worker/mail-api.test.ts`: new test. It adds a second domain with
  `is_enabled = 0` and a granted mailbox on it. The v1 list returns `domainEnabled: false` for that
  mailbox and `true` for the mailbox on the active domain. The test then turns the domain on and
  checks that the value becomes `true`. It also checks that each v2 mailbox has exactly the
  existing v2 key set, so the test fails if domain state leaks into v2. The test removes its rows
  when it ends.
- The existing exact v1 mailbox response check now includes `domainEnabled: true`.
- `test/unit/scripts/mail-api-artifacts.test.mjs`: checks that the v1 schema lists the field as a
  required boolean and that the v2 `Mailbox` schema does not get it.
- I made the new integration test fail on purpose twice. When the server always sent `true`, it
  failed with `mbx_api_off: true` where `false` was expected. When the v2 list got an extra
  `domainEnabled` key, the v2 key-set check failed. It passes with the real code.

Local results:

- `pnpm code:check`, `pnpm typecheck`, `pnpm api:check`, `pnpm test:architecture`: pass.
- `pnpm test:integration`: 45 files, 225 tests pass.
- `pnpm test:unit`: 954 pass. 11 fail in two compose test files
  (`compose-recovery.test.ts`, `use-draft-autosave.test.tsx`) with
  `Cannot read properties of undefined (reading 'clear')` on `localStorage`. These files are not
  touched by this change. The cause looks like Node 26's built-in `localStorage` on my machine.
- `pnpm deploy:dry-run`: pass.

### Compatibility notes

- Additive under the v1 rule. Existing clients ignore the new field.
- `domainEnabled` shows only the owner's switch. A domain can be active but still not ready (for
  example, `receiving_status` is `pending` or `degraded`). That state is not part of this change.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

---

## Follow-ups (separate issues)

These are not part of this PR.

1. **No wake event on domain changes.** Turning a domain on or off, or disconnecting it, does not
   publish a `mailboxes` event. Clients on the events socket see the new `domainEnabled` value only
   when they next list mailboxes.
2. **Sending ignores the mailbox switch.** `findMailboxForSending`
   (`worker/features/mailboxes/queries.ts`) checks `d.is_enabled = 1` and `d.sending_status =
   'ready'`, but not `m.is_active = 1`. v1 reports `sendEnabled: mailbox.isActive`, so v1 can say
   `sendEnabled: false` for a mailbox that the server still lets send.
3. **Spec first.** HQBase AGENTS.md asks for the canonical spec in
   `hqbase-site/src/content/docs/docs/specs/` to change before the code. Do this before filing the
   issue and PR.
