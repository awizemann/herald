Thanks — the four inline comments and the canonical-host contract were all fair. I rewrote the
command around the contract in `specs/multi-domain.md` instead of patching the one-step replacement.

## Design

`hqbase domain` is now attach → verify → cutover → redirect, with a staged manifest and rollback.

- **Staged state.** `manifest.domainMove` records the proposal before the first Cloudflare call.
  `appDomain`, `authUrl`, and the new `retiredDomains` are written only after every step is verified.
  `assertUnambiguousManifest` refuses every other lifecycle command while a move is unfinished, so
  doctor, recovery, and removal never read a record that does not describe the deployed resources.
  The domain command itself resumes; each step is idempotent.
- **Custom domains through the API.** Worker custom domains are read and written with
  `GET/PUT/DELETE /accounts/:id/workers/domains`, which is what the Worker already uses in
  `worker/features/setup/cloudflare.ts`. Wrangler never publishes the domain now.
- **Service origin.** `BETTER_AUTH_URL` is the machine-facing service origin in this codebase: the
  auth issuer, the Mail API audience (`/api/v1`), the MCP audiences, and the origin advertised by
  the discovery documents. `worker/index.ts` only 308-redirects `text/html` on a non-canonical
  portal host, so a hostname that stays attached keeps serving machines. A portal move therefore
  keeps the old hostname attached and does **not** move the service origin. When the service origin
  is served by the hostname being replaced, the command stops and requires either
  `--keep-service-origin` or `--move-service-origin`.
- **`triggers deploy` is gone.** The cutover is a configuration deployment of the release that is
  already active (`scripts/release/deploy.mjs --configuration-only`). It refuses to run when the
  Worker has no active signed release or runs a different version, and it verifies a new active
  version with the signed release tag afterwards.

## Point by point

1. **Detach leaves the domain and DNS record attached.** Detach now deletes the custom-domain record
   explicitly and re-lists to confirm it is gone; the same code path removes a retired hostname on
   `--detach-old`. Both need `--yes`, because they delete a DNS record.
   Tests: *really deletes the custom domain and its DNS record on detach*, *deletes the previous
   hostname only when the operator asks for it*, *refuses to detach without --yes*.

2. **Same-release path skips `BETTER_AUTH_URL`.** Added `deployConfiguration()` in
   `scripts/release/deploy.mjs` and the `--configuration-only` entry point: same signed release,
   `wrangler deploy --keep-vars --tag <release tag>`, then `inspectActiveRelease` must report a new
   active version. The command then reads `https://<host>/api/v1/openapi.json` and fails closed
   unless the advertised service origin equals the manifest value — the deployed variable contract,
   asserted end to end.
   Tests: *deploys the new service origin as configuration for the active release*, *fails closed
   when the deployed service origin does not match the manifest*, *verifies that a configuration
   deployment produced a new active version* (`deploy.test.mjs`).

3. **Non-TTY auto-override.** The changeset is inspected first (`planAttachment` over the live domain
   list). A hostname that routes to another Worker is refused by name. `--override-existing` alone is
   not enough — `--yes` is required as well, and there is no "a TTY is attached, so this is
   confirmed" path. The `PUT` always sends `override_existing_origin` and
   `override_existing_dns_record` explicitly, `false` unless asked.
   Tests: *refuses a hostname that already routes to another Worker*, *refuses to take over a
   hostname without an explicit confirmation*, *never lets Cloudflare override an origin or DNS
   record implicitly*.

4. **Manifest and config committed before Cloudflare validates.** Covered by the staged-move record
   above. On a partial failure the command deletes the record it created (never one it took over),
   redeploys the previously committed configuration, keeps the saved record, prints the recovery
   call, and exits non-zero.
   Tests: *rolls back the attachment and keeps the saved record when verification fails*, *redeploys
   the previous configuration when the cutover fails*, *resumes the same move and refuses a
   different one*, *does not write anything for a dry run*.

## Documentation

Companion `hqbase-site` change is ready: a new `## Operator portal moves` section on
`specs/multi-domain.md`, a `## Move the workspace address` section on `guides/deployment.md`, and one
`domain` bullet on `operations.md`. I will open it as a separate PR so it lands first — say the word
if you would rather it be shaped differently.

## Validation

`CI=true pnpm check` is green except the pre-existing `use-draft-autosave.test.tsx` localStorage case
under Node 26.5, which fails the same way on a clean `main` worktree here. Unit and integration
suites, Biome, typecheck, API check, architecture check, and the build all pass.

## Open questions

1. The command needs `CLOUDFLARE_API_TOKEN` (Workers Scripts:Edit, Zone:Read, DNS:Edit) because
   Wrangler has no custom-domain command. Every other operator command works from `wrangler login`.
   Is a token acceptable here, or would you rather reuse the Wrangler grant another way?
2. The redirect step writes the canonical `workspace_hosts` row with `wrangler d1 execute --remote`,
   mirroring `upsertWorkspaceHost`. Would you prefer an operator-only endpoint so that SQL lives in
   one place?
3. Should `install --app-domain` stop pinning `BETTER_AUTH_URL` to the portal host? Today the two
   coincide, which is the only reason a move needs `--keep-service-origin` / `--move-service-origin`.
4. Retired hostnames stay attached until an explicit `--detach-old`. Do you want a recorded grace
   period instead?

Also: CI was `action_required` at the previous head, so the application gates have not run on this
branch yet. Happy to rebase or squash however you prefer before it does.
