# Herald upgrade plan for HQBase 1.4.x (1.4.0 → 1.4.2)

Date: 2026-09-19. Status: APPROVED by Alan 2026-09-19 (signatures editor: yes; labels: journal + slow reconciliation).
Sources: upstream tags v1.4.0/v1.4.1/v1.4.2 (fetched into ~/Developer/hqbase), CHANGELOG.md,
`api/hqbase-mail-api-v1.openapi.json` diff v1.3.4→v1.4.2, worker source diff (auth, messages,
send, drafts, signatures), and a trial regeneration of HeraldKit against the 1.4.2 spec.

## What changed upstream that touches Herald

| Area | Change (1.4.x) | Herald today | Effect |
|---|---|---|---|
| OAuth session binding | `offline_access` tokens no longer die with the 7-day browser session (`oauth-principal.ts`: LEFT JOIN session, skip the expiry check when token+consent hold offline_access). Password reset now revokes all OAuth tokens/consents for the user. | Auto minimal re-auth when frontmost + banner fallback (P2, cc61d02). Upstream issue #114 was ours. | The periodic re-auth class disappears on 1.4.2 servers. Nothing to change in code; keep the fallback for revocation/password-reset. Memory note must be corrected. |
| Labels on v1 | `includeLabels=true` on GET /messages, /messages/{id}, /messages/{id}/thread, /conversations, /changes and POST /messages/{id}/{action} embeds `labels: Label[]` on MessageSummary. Upstream issue #115 was ours. | Per-label sweep: one `GET /messages?labelId=` page-walk per label every 120 s (750 s idle). | Journal upserts carry full membership, so the sweep becomes a rare reconciliation. |
| Send idempotency | `idempotencyKey` (1–100 chars) on SendInput/ReplyInput/ForwardInput. Identity = key, else `draft:<draftId>`, else fresh. Replay returns the stored 201; different body under the same key is 409 `SEND_KEY_CONFLICT`; 503 `SEND_RECOVERY_UNAVAILABLE` ("Do not send it again") and 503 `SEND_STORAGE_NOT_READY`. | send/reply carry `draftId` when autosaved; forward never; pre-autosave send never. Failure leaves the window open for a manual retry. | Forwards and pre-autosave sends can double-deliver on retry today. |
| Signature management | `POST /signatures`, `GET /signatures/manage`, `PATCH/DELETE /signatures/{id}` behind new scope `signatures:manage`; `scopes_supported` advertises it. Upstream #112 was ours. | Consumes signatures only; `OAuthDiscovery.requestedScopes` requests everything advertised. | Adopt with a Settings ▸ Signatures editor and move to an explicit scope list. |
| Spec structure | `DraftInput`/`Draft` now `allOf[DraftFields, …]` upstream (#113 adopted). `SignatureSnapshot.id` nullable. `MessageDetail.replyTo: string[]` optional. | Herald-local `DraftFields` patch. Trial regen: two compile errors, both `Mapping.swift:286-290`. | Re-vendor is cheap. |
| Drafts | Conflicting saves rejected (409); paging fix; signature schema corrected. | Handled. | Verify live. |
| Trash retention | Default 30-day Trash purge. | Journal tombstones. | Verify. |
| Platform | Schema v4, `send_operations`, migration 0029, Nightly channel. | n/a | Test instance re-stood-up at v1.4.2. |

Unchanged: `/events`, change journal shape, action enums, pagination, attachments, auth discovery/registration.

## Decisions (Alan, 2026-09-19)
- Signatures: Option A — build Settings ▸ Signatures (plain HTML body field + live preview first), adopt `signatures:manage`, and switch scope requests to an explicit list so future upstream scopes cannot widen consent silently. Ship the scope with the UI.
- Labels: Option B — membership from `includeLabels` rows and journal upserts; keep ONE reconciliation sweep on a long timer (~30 min) and on label-list changes (`labels` wake frame), because label deletion never touches messages and frames are best-effort.

## Phases (Memophant tasks) and orchestration

Dependency graph: U0 ∥ U1 → (U2 ∥ U3 ∥ U4, each in its own git worktree) → U5 → U6 → U7.
U1 owns EVERY shared file (spec, generated client, `MailAPIClient` protocol, `HQBaseAPIClient`, `Mapping.swift`, DTOs, `FakeServer`, `OAuthDiscovery`) so U2–U4 only touch their own domains and merge cleanly.

| Task | Scope | Owner | Files |
|---|---|---|---|
| U0 t-451c4980 | v1.4.2 test instance; live session-binding check; ops + auth memory notes | sonnet agent | scratchpad worktree of ~/Developer/hqbase; .memory via MCP |
| U1 t-2547e466 | re-vendor + regen; API surface for includeLabels, idempotencyKey, signature CRUD; explicit scope list; tests | opus agent, main tree | HeraldKit/Sources/HeraldAPI, HeraldKit/Sources/HeraldKit/API, Auth/OAuthDiscovery, Tests/Support fake server |
| U2 t-bdd6b056 | labels from rows; reconciliation sweep | opus agent, worktree | Sync/SyncEngine, MailStore+Labels, MailStore+Mapping, Herald/App/MailViewModel+Labels, LabelsTests |
| U3 t-fe56989b | idempotency key; SEND_* mapping; replyTo prefill; null snapshot id test | opus agent, worktree | Compose/ComposeDraft, OutboxService, ComposePrefill, Herald/Compose/ComposeViewModel, tests |
| U4 t-d7c3e3f8 | signatures editor | opus agent, worktree | new Compose/SignatureManagementService, Herald/Views/SettingsView (+ new Signatures view), tests |
| U5 t-4680dc24 | integrate, build, live dogfood, plan + memory audit | orchestrator | — |
| U6 t-a652842a | fresh-eyes audit of the whole touched surface → fix tasks | specialist agents | — |
| U7 t-f2e60746 | release 0.5.0 | after approval | CHANGELOG, project.yml, release.sh |

## Risks / open questions
- `includeLabels` on `/changes` adds a label join per page; confirm cost on the test instance.
- Conversation label union computed locally must agree with `LabelAssignmentResult.labels` after a conversation-level PUT.
- Accounts consented before U4 lack `signatures:manage`; the editor must hide with a "re-sign-in to manage signatures" hint (403 insufficient_scope) rather than fail.
- Servers < 1.4.2 ignore `includeLabels` → rows have no `labels`; U2 must treat absence as "unknown, keep the sweep as source", not as "no labels".

## Compatibility floor (Alan, 2026-09-19: production auto-update offers 1.4.0, not 1.4.2)
Verified from tags: `idempotencyKey` is 1.4.0; `includeLabels`, `signatures:manage`/CRUD and the session-binding fix are 1.4.2.
Rules for U2–U4 and the release:
- Minimum server stays **1.3.4**. Herald 0.5.0 must run unchanged on 1.3.4 and 1.4.0 servers.
- Never detect by version. Labels: a `labels` key present on a row = authoritative; absent = unknown, sweep stays the source at today's cadence. Signatures editor: shown only when the account's token holds `signatures:manage` (advertised scope intersected at consent; 403 insufficient_scope → hint to re-sign-in; 404 → server too old, hide). Idempotency key: always sent (Zod strips unknown keys on older servers).
- Auto re-auth stays; the session-binding class only closes for users on ≥1.4.2.
