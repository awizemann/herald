---
created: 2026-09-29
updated: 2026-09-29
---

# Local HQBase Testing

To test Herald against a real (local) HQBase server, you can run HQBase locally and point Herald's sign-in at it.

## Set up a local HQBase instance

HQBase uses Cloudflare Workers Runtime (Wrangler). Clone or check out the HQBase repository in a sibling directory, then run the dev server:

```sh
cd ~/Developer/hqbase  # or wherever your HQBase checkout is
pnpm dev
```

This builds the HQBase app and starts a local Wrangler dev server on port 8787 (or the next available port). The dev instance runs entirely offline — no network calls to Cloudflare — so you can test freely without side effects.

## Point Herald to your local server

1. **Sign in to Herald** using a build from `./scripts/build-detached.sh` (the debug build).
2. When the OAuth flow starts and `ASWebAuthenticationSession` opens the system web view, the URL will show the HQBase origin.
3. **Before** authorizing, manually edit the URL in the web view:
   - Change the host from your normal HQBase domain to `localhost:8787` (or whatever port Wrangler is using)
   - Keep the rest of the URL intact
4. Complete authorization. Herald will use the local HQBase instance for all subsequent API calls.

## Populate test data

HQBase's dev server includes seed data (test mailboxes, messages, accounts). If you need to add or reset data:

```sh
# In the hqbase checkout
pnpm dev  # restart the dev server to clear memory
```

The dev instance stores nothing permanently, so every restart is a fresh state.

## Debugging

- **Wrangler logs** — Check the terminal running `pnpm dev` for request logs and errors.
- **Herald logs** — Herald logs API calls, sync cycles, and errors to the system Console (app → Console.app, then search for `herald` in the search box).
- **Network traffic** — Herald's API calls are plain HTTP to `localhost:8787`, so you can inspect them with tools like `mitmproxy` or by adding logging to HQBase's request handlers.

---
_Last updated: 2026-09-29 — local testing setup and debugging_