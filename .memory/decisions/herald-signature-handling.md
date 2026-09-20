---
title: Herald Signature Handling
type: note
permalink: hqbase-mac/decisions/herald-signature-handling
tags: [herald, compose, signatures, settings, upstream-134, upstream-142]
source_paths: [HeraldKit/Sources/HeraldKit/Model/Signature.swift, HeraldKit/Sources/HeraldKit/Compose/SignatureManagementService.swift, Herald/App/SignatureSettingsModel.swift, Herald/Views/SignatureSettingsView.swift, HeraldKit/Sources/HeraldKit/Compose/ComposeDraft.swift, HeraldKit/Sources/HeraldKit/Compose/OutboxService.swift, Herald/Compose/ComposeViewModel.swift, Herald/Compose/ComposeWindow.swift, HeraldKit/Sources/HeraldAPI/openapi.json]
source_paths_inferred: false
source_sha: 7e5eb159db68edaac988bfd21ae27c5ae670639d
created: 2026-09-04
updated: 2026-09-19
reviewed: 2026-09-09
reviewed_by: audit:claude-code (background)
---

How Herald adopted upstream 1.3.4 signatures (P7, task t-65e6e8d4, commit 3d99c49). The server appends the signature itself, so Herald's job is to state a SELECTION and keep the draft's stored snapshot in agreement with what the compose window shows. The verified server semantics live in the API contract note.

## Observations
- [decision] Herald sends a signature SELECTION on every draft/send/reply/forward and never concatenates signature text into the body — the server appends it (assembleMessageBody), the same invariant class as the quoted original #signatures
- [decision] Compose defaults to `.automatic` and the picker offers an explicit "Default · <name>" row, so re-picking the shown signature cannot silently pin today's default #compose
- [decision] A send carrying a draftId uses the DRAFT's snapshot, so OutboxService.send saves the draft first when selection and stored snapshot disagree (the switch-inside-the-autosave-debounce race); skipped for POST /forward, which carries no draftId #compose
- [decision] The resolved snapshot is cached on CachedDraft so reopening a draft keeps its choice ("No signature" included) instead of re-applying the default on the next autosave #sync
- [gotcha] The no-signature case is spelled `.noSignature`: `signature: .none` on the optional field would bind to Optional.none and OMIT the field, which the server reads as something else #api

## Relations
- relates_to [[HQBase Mail API v1 Contract]]


## Signature management (Settings ▸ Signatures, upstream 1.4.2, U4 t-d7c3e3f8)

Adopting `signatures:manage`. The send-time invariant above is UNCHANGED: managing a signature never makes Herald concatenate one — the server still appends at send.

### Error semantics → pane states
`SignatureManagementService` (HeraldKit actor, mirrors `OutboxService`) is the ONLY place HTTP becomes UI state. `SignatureManagementError` is deliberately not a `MailAPIError` passthrough:
- 403 `insufficient_scope` → `.notAuthorized` — consented before the scope shipped; only a fresh sign-in helps, so no retry is offered. Pane offers `AppEnvironment.reauthenticate(accountID:)`.
- 404 on `GET /signatures/manage` → `.unsupportedByServer` — a 1.4.2+ server answers that route 200 with a possibly-empty list, so 404 can only be an absent route (server < 1.4.2). No retry.
- 404 on a single-id PATCH/DELETE → `.signatureGone`, NOT a compatibility state: ambiguous at the HTTP level, so the pane re-lists and a genuinely old server then reports `.unsupportedByServer` from the list.
- 403 `SIGNATURE_FORBIDDEN` → `.scopeForbidden` (signing in again changes nothing); 409 `SIGNATURE_NAME_CONFLICT` → `.duplicateName`.

### Scope derivation (reconstructed, not fetched)
`GET /signatures/manage` returns a bare `Signature[]` — there is no "what may I manage" route. `SignatureSettingsModel.scopeOptions(mailboxes:existing:)` rebuilds the picker:
- **Personal is offered ONLY when an existing user-scoped signature reveals the user id.** Upstream `requireManageScope` rejects `scope.id != actor.id`, and no route tells a client its own user id. A user with zero personal signatures therefore cannot create their first one from Herald — an upstream gap, not a Herald bug.
- Mailboxes: `accessLevel == .manager` or `nil` (unreported is offered; the server is the authority and hiding a usable scope is the worse failure). `.read`/`.agent` are hidden.
- Domains: distinct `MailboxAddress.mailDomainID`, labelled by the address's domain part. Upstream additionally requires owner/admin, which the client cannot see, so a refusal surfaces as `.scopeForbidden`.

### Invariants
- Scope is IMMUTABLE on an existing signature: `PATCH /signatures/{id}` has no scope field, so the editor states the scope rather than offering a picker.
- An empty `UpdateSignatureInput` is never sent (guaranteed 400 `SIGNATURE_INVALID`); `update` returns `Signature?` with `nil` meaning "nothing to send".
- `isDefault` goes in the PATCH only when it CHANGED — sending `false` for an untouched toggle would demote a default the user never meant to clear.
- Every mutation is followed by a fresh `list()`, never a local array patch: the server demotes the previous default of a scope, a rule no local edit could reproduce.
- Grouping order is total and deterministic (personal → mailbox → domain, then label, then name) so a refresh cannot reshuffle rows under the cursor.
- Preview keeps `MessageWebView`'s containment posture: JS off, nil base URL, `RemoteContentBlocker` rule list required (refuses to render without it), all navigation but our own cancelled through the shared `NavigationPolicy`.
- Compose invalidation: `AppEnvironment.signatureRevision` is bumped after any mutation and `ComposeWindow`'s candidate `.task(id:)` is keyed on it, so an already-open composer stops offering a renamed/deleted signature.

Commit 3eee453. Tests: 12 HeraldKit (318→330), 16 app-hosted (255→271).


### Hardening pass (2026-09-19 — audit F2, t-45bafcc3)

- [decision] `insufficient_scope` on the list route is no longer one screen but two. `.needsReauthorization` (offers "Sign In Again") is honest only while a fresh token could plausibly differ. It becomes the TERMINAL `.cannotManage` when the account's granted scope string already contains `signatures:manage` and the server refuses anyway, or when a sign-in has already been through and the new grant still lacks it. An EMPTY granted-scope list is "unknown", never "lacks it" — the pane must not declare a terminal state on missing information. `SignatureSettingsModel.signInAgainRequested()` is called by the button before the flow starts #signatures
- [constraint] P3 is implemented and tested but INERT in production until `AppEnvironment.signatureSettingsModel()` passes `grantedScopes: { graph.account.scopes }`; the parameter defaults to `{ [] }`, which preserves today's behaviour. `forgetSignatureSettings(accountID:)` also drops the model on a re-auth that replaces the graph, so the `hasRetriedSignIn` latch does not survive one — the granted-scope comparison is the signal that actually has to carry it #signatures
- [gotcha] `save()` cleared `self.editor` unconditionally after its await, so a save landing after the user cancelled and opened a NEW sheet closed the new one and discarded what they had typed. The check is identity (`if self.editor === editor`), not existence #compose
- [gotcha] The delete confirmation was titled off `pendingDeletion?.name`, which `confirmDeletion()` clears immediately — SwiftUI re-reads the title through the dismissal animation and retitled it “Delete “”?” in front of the user. `deletionPromptName` outlives `pendingDeletion` on purpose #signatures
- [convention] `SignatureManagementError.logCode` is payload-free and forwards `MailAPIError.logCode` for `.api`. `String(describing:)` on this enum prints the server's free-text `message`, which is the rule every other Herald call site already avoided #logging
