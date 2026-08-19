# `hqbase domain` — design note (PR #34, revision 2)

Scope: the terminal operator command only. The Deploy to Cloudflare button, the setup wizard, the
in-app portal cutover (`PUT /api/domains/portal`), and the signed release implementation are
unchanged. D1, R2, and queues are never touched.

## The contract this implements

`hqbase-site` `specs/multi-domain.md` (`## Hosts`) already defines the contract the maintainer
referred to:

> The workspace has one mutable canonical portal hostname and one stable machine-facing service
> origin. Owners and admins may change the portal after recent reauthentication through an
> attach-verify-cutover-redirect workflow with rollback. Portal changes never change the webhook,
> recovery, or automation origin.

### What the service origin is, concretely

In this repository the machine-facing service origin **is** `BETTER_AUTH_URL`. `worker/auth/auth.ts`
derives everything from it:

- `authOrigin()` → Better Auth `baseURL` and `authIssuer()`
- `mailApiResource()` → `<origin>/api/v1` — the Mail API OAuth audience
- `mcpResource()` / `mcpFullResource()` → `<origin>/mcp`, `<origin>/mcp/full`
- `worker/features/mail-api/discovery.ts` publishes it in the SKILL.md and in the OpenAPI
  `servers[0].url`

There is no second, separate machine origin today. So:

- Moving `BETTER_AUTH_URL` invalidates the audience of every agent token, every registered OAuth
  client redirect URI, and every webhook that used the old origin.
- The portal host and the service origin are decoupled at the request level already:
  `worker/index.ts` 308-redirects to the canonical portal host **only** for `text/html` requests on
  a known non-canonical `workspace_hosts` row. `/api/*`, `/mcp`, and the discovery paths are never
  redirected, so a hostname that stays attached keeps serving machines unchanged.

Therefore the command treats a portal move and a service-origin move as two different decisions, and
refuses to guess when they collide (see "Fail-closed rules").

## State machine

Committed state = `manifest.appDomain`, `manifest.authUrl`, `manifest.retiredDomains` and the
generated `wrangler.jsonc`. Proposed state = `manifest.domainMove`, written before the first
Cloudflare mutation and removed only on success.

| Step | Action | Verification | Rollback if it fails |
| --- | --- | --- | --- |
| 0 preflight | `resolveCloudflareAccount` + `prepareManifest` (#40 helpers); compute the proposal; refuse a conflicting unfinished move | manifest v3, live D1/R2/queue identity | nothing was changed |
| 1 stage | write `domainMove` (state `staged`) | — | manifest keeps committed routing values |
| 2 attach | `PUT /accounts/:id/workers/domains` with `override_existing_origin` and `override_existing_dns_record` set explicitly | re-list domains; hostname must map to this Worker | delete the record this run created |
| 3 verify | probe `https://<new host>/api/v1/openapi.json` (10 × 3 s) | HTTP 200 and a `servers[0].url` — proves DNS, certificate, and a healthy origin | delete the record this run created |
| 4 cutover | write `wrangler.jsonc` (routes = new host + retained hosts, `vars.BETTER_AUTH_URL`), then `deploy.mjs --configuration-only` | the deploy asserts a **new** active version carrying the signed release tag; then the probe asserts the advertised service origin equals the manifest value | re-write the committed config and redeploy it, then delete the record this run created |
| 5 redirect | `wrangler d1 execute --remote`: upsert the new `workspace_hosts` portal row, clear `is_canonical`, set the new host canonical | the unique canonical-portal index enforces one canonical host | as step 4 |
| 6 detach | delete only hostnames this deployment owns that the target no longer keeps | re-list; refuse to finish while Cloudflare still reports them | as step 4 |
| 7 commit | write `appDomain`, `authUrl`, `retiredDomains`; delete `domainMove`; regenerate config | — | — |

Nothing destructive happens before step 3. Every step is idempotent, so re-running the same command
resumes: attach becomes a no-op when the hostname already maps to this Worker, the configuration
deployment is repeatable, the D1 upsert is `ON CONFLICT DO UPDATE`, and a deletion is skipped when
the record is already gone.

`assertUnambiguousManifest` now refuses any other lifecycle command (install, destroy, dry runs)
while `domainMove` is present, so `doctor`, recovery, and removal never act on a record that does not
describe the deployed resources. `domain` itself passes `allowDomainMove` so it can resume.

## Rollback

- Attach failed → nothing to undo; the manifest still describes the old hostname.
- Verify failed → delete the record this run created (never a record we took over with
  `--override-existing`; that case prints the exact recovery call instead).
- Cutover or redirect failed → regenerate the committed configuration and redeploy it, then delete
  the record this run created.
- Rollback itself failed → the failure is printed, `domainMove` is kept with its last state, and the
  operator gets the `DELETE /accounts/:id/workers/domains/:id` recovery line. The command always
  exits non-zero.

## TTY / non-TTY conflict handling

`command.mjs` captures child stdout, so Wrangler always sees a non-TTY process and (4.114) enables
`override_existing_origin` and `override_existing_dns_record` for custom-domain publication. The
command therefore never lets Wrangler publish the domain:

1. `GET /accounts/:id/workers/domains` classifies the change before anything is mutated
   (`planAttachment`: `attach`, `keep`, `conflict`).
2. `conflict` is refused with the offending Worker name unless `--override-existing`.
3. `--override-existing` alone is not enough: the operator must also pass `--yes`. There is no
   implicit "a TTY is attached, so this is confirmed" path.
4. The `PUT` always sends both override flags explicitly, `false` unless the operator asked.

## Fail-closed rules

- `--detach` and `--detach-old` require `--yes` (they delete a DNS record).
- A portal move whose current service origin is the hostname being replaced requires exactly one of
  `--keep-service-origin` (old hostname stays attached and serves automation) or
  `--move-service-origin` (auth issuer, Mail API audience, MCP audience move; everything must be
  re-registered).
- `--detach-old` is refused while that hostname serves the service origin.
- `--auth-url` cannot be combined with `--detach`: no custom hostname survives it.
- Customer-managed OAuth still requires a canonical origin, so a detach that drops it is refused.
- `wrangler triggers deploy` is gone. The cutover is a configuration deployment of the already
  active signed release (`deploy.mjs --configuration-only`), which refuses to run when the Worker has
  no active release or runs a different version, and verifies a new active version afterwards.
- The command needs `CLOUDFLARE_API_TOKEN` (Workers Scripts:Edit, Zone:Read, DNS:Edit) and says so.

## Test plan (`test/unit/scripts/domain.test.mjs`, `deploy.test.mjs`)

Command-level tests drive `configureDomain` end to end against a fake Wrangler runner, a fake
custom-domains API, a fake configuration deploy, and a fake origin probe, using a real manifest on
disk under `.hqbase/deployments/`:

1. attach → verify → cutover → redirect → commit; D1, R2, and queue records unchanged.
2. the old hostname stays attached, the config keeps both routes, and the D1 statement makes the new
   host canonical.
3. `--detach-old --yes` deletes the previous hostname.
4. `--detach --yes` really calls the domain deletion and clears the route and `BETTER_AUTH_URL`.
5. `--detach` without `--yes` changes nothing.
6. the configuration deployment carries the new `BETTER_AUTH_URL`.
7. a mismatched advertised service origin fails closed and leaves the manifest committed to the old
   hostname.
8. a hostname owned by another Worker is refused; with `--override-existing` but no `--yes` it is
   still refused, and nothing is called.
9. verification failure rolls the attachment back and keeps the saved record (`rolled-back`).
10. cutover failure redeploys the previous configuration.
11. `--dry-run` writes nothing and calls nothing.
12. an unfinished move blocks other lifecycle commands, refuses a different target, and resumes the
    same target without re-attaching.
13. the API seam always sends `override_existing_*: false`, deletes by record id, and requires a
    token; `deployConfiguration` fails closed when Cloudflare reports no new active version.

## Open questions for the maintainer

1. **Token.** Wrangler has no custom-domain command, so the operator uses the REST API and needs
   `CLOUDFLARE_API_TOKEN`. Every other operator command works from `wrangler login`. Is a token
   acceptable here, or should the command reuse the Wrangler OAuth grant another way?
2. **`workspace_hosts` from the terminal.** The redirect step writes the canonical portal row with
   `wrangler d1 execute --remote`, mirroring `upsertWorkspaceHost`. Would you rather have an
   operator-only API endpoint so the SQL contract lives in one place?
3. **Service origin.** Should `install --app-domain` stop pinning `BETTER_AUTH_URL` to the portal
   host, so the two are separable from the start? Today they coincide, which is why the move needs
   `--keep-service-origin` / `--move-service-origin`.
4. **Grace period.** Retired hostnames currently stay attached until an explicit `--detach-old`. Is
   a recorded expiry wanted, or is explicit removal enough?
