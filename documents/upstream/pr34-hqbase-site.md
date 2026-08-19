# Companion `hqbase-site` changes for PR #34

Exact page edits, in the shape PR #40 used for its docs PR (HQBase/hqbase-site#12): one new `##`
section on the spec page that already owns the contract, plus one operator section on the reader
guide. No new page, no frontmatter changes, no `updated`/status fields, ATX headings, hard wrap at
~100 columns, Simplified Technical English.

A literal `.patch` is not included on purpose: the anchors below are short and stable, and a hand
written diff against a tree I did not build would be more fragile than the instructions. Every block
below is final copy, ready to paste.

---

## 1. `src/content/docs/docs/specs/multi-domain.md`

Add a new section after `## Hosts` (before `## Provisioning`). It states the operator side of the
existing canonical-host contract.

```markdown
## Operator portal moves

This contract applies to the terminal operator command. It does not change the setup wizard or the
in-app portal cutover.

- `pnpm hqbase domain --name <name> --app-domain <host>` moves the canonical portal hostname with an
  attach, verify, cutover, redirect sequence. It never changes D1, R2, or queues.
- The command records the proposed move in `.hqbase/deployments/<name>/manifest.json` before the
  first Cloudflare change, and saves the new hostname only after every step is verified. Other
  lifecycle commands refuse to run while a move is unfinished.
- Verification attaches the hostname, confirms that Cloudflare reports it for this Worker, and reads
  the installation discovery document on the new hostname before any cutover.
- The cutover deploys configuration for the release that is already active, then confirms that the
  installation advertises the expected service origin.
- The previous hostname stays attached and redirects browsers to the canonical portal. Its API, MCP,
  and mail discovery answers do not change. Removal is a separate confirmed step.
- A portal move does not move the machine-facing service origin. When the service origin is served
  by the hostname that is replaced, the command stops and asks the operator to keep it or move it.
  Moving it ends every agent token, OAuth redirect URI, and webhook registered on the old origin.
- The command reads and writes Worker custom domains through the Cloudflare API, so a hostname that
  already routes to another Worker is refused. An operator can take it over only with an explicit
  confirmation.
- A failure rolls back the attachment and the deployed configuration, keeps the saved record, and
  prints the recovery steps. Running the same command again resumes the move.
```

---

## 2. `src/content/docs/docs/guides/deployment.md`

Add a new section after `## Switch an existing deployment` (or after the OAuth section, wherever the
named-deployment operator commands end) and before `## Remove HQBase`.

```markdown
## Move the workspace address

Use the named deployment operator so the local deployment record, generated Wrangler configuration,
and deployed Worker stay aligned. The hostname must be a zone in the same Cloudflare account, and
the command needs `CLOUDFLARE_API_TOKEN` with Workers Scripts:Edit, Zone:Read, and DNS:Edit:

```sh
pnpm hqbase domain \
  --name production \
  --app-domain mail.example.com \
  --keep-service-origin
```

The command attaches the new hostname, waits until it serves the installation, deploys the
configuration, and then makes it the canonical portal address. The previous hostname stays attached
and redirects people to the new address, so agents, webhooks, and mail discovery keep working.

Use `--move-service-origin` instead of `--keep-service-origin` to move the machine-facing service
origin to the new hostname. Every agent token, OAuth redirect URI, and webhook on the old origin
must then be registered again.

Validate the change without contacting Cloudflare, writing files, or deploying:

```sh
pnpm hqbase domain --name production --app-domain mail.example.com --dry-run
```

Remove the previous hostname after the move, or remove every custom hostname and serve from the
default Worker address:

```sh
pnpm hqbase domain --name production --app-domain mail.example.com --detach-old --yes
pnpm hqbase domain --name production --detach --move-service-origin --yes
```

Both commands delete a Cloudflare DNS record, so they need `--yes`. If a step fails, the command
rolls the change back, keeps the saved deployment record, and prints how to continue. Run the same
command again to resume.
```

---

## 3. `src/content/docs/docs/operations.md`

Add one bullet to the `## Back up, restore, or diagnose` list, after the `doctor` bullet.

```markdown
- **`domain`** moves the canonical portal address. It attaches the new hostname, verifies it,
  deploys configuration, and then redirects the previous hostname. It does not change mail data,
  storage, or queues, and it refuses to continue while a previous move is unfinished.
```

---

## Checks to run in `hqbase-site`

```sh
pnpm check
pnpm test:docs
```

No `astro.config.mjs` change is needed because no page is added.
