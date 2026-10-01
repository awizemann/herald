---
title: Herald AI Classification via Cloudflare AI Gateway
type: note
permalink: hqbase-mac/decisions/herald-ai-classification-via-cloudflare-ai-gateway
tags: [ai, workflows, classification]
source_paths: [HeraldKit/Sources/HeraldKit/AI/AIGatewayClient.swift, HeraldKit/Sources/HeraldKit/AI/EmailClassifier.swift, HeraldKit/Sources/HeraldKit/AI/ClassificationEngine.swift, Herald/Support/AIGatewaySettings.swift, Herald/Support/WorkflowPreferences.swift, Herald/Support/ClassificationSupport.swift, Herald/Views/Settings/SettingsWorkflowsPage.swift, Herald/Views/Settings/SettingsAIGatewayPage.swift, Herald/Views/Settings/SettingsRootPages.swift, Herald/App/MailViewModel.swift, Herald/App/SettingsRoute.swift]
source_paths_inferred: false
source_sha: 2d441e9a9ad57500bef916f829b4ad0b9934e258
created: 2026-09-29
updated: 2026-09-29
reviewed: 2026-09-29
reviewed_by: audit:claude-code (background)
---
Herald's one AI feature: opt-in, per-domain classification of new mail into existing HQBase labels, through the user's own Cloudflare AI Gateway. Built in phases WF1–WF5 on branch `feature/workflows-classification` (e28dead, 5aa2c3f, 5de4c46, b9c8650, 32feecb, WF5). Current state as of 2026-09-29.

## Observations
- [decision] Transport: OpenAI-compatible `https://gateway.ai.cloudflare.com/v1/{account}/{gateway}/compat/chat/completions`, auth ONLY `cf-aig-authorization: Bearer <gateway token>`; Workers AI models only (`workers-ai/@cf/...`), no third-party providers (they need gateway credits: 402, code 2021). Token in Herald's Keychain namespace at `AIGatewayClient.tokenKey`, never in chat/files/UserDefaults #ai #security
- [decision] Classify each THREAD once: only the first inbound inbox message of a thread with no label at all, received after the domain's `enabledAt`; a thread with any label (model, human, other device) is never re-classified. No backfill #workflow
- [decision] Default model `@cf/qwen/qwen3-30b-a3b-fp8` (`/no_think`): 9/11 on the shabubox eval, ~0.5s/call #eval
- [gotcha] Tag descriptions dominate accuracy more than model choice — they must say what is EXCLUDED where tags overlap; model self-reported confidence is useless (always 0.8–0.95) — never gate on it #eval
- [gotcha] The server re-check (GET thread with includeLabels) cannot see labels on a pre-1.4.2 server (labels nil → treated as unlabelled) nor messages in mailboxes the user cannot access; the cache re-check before apply is the last guard #workflow

## Transport & secrets
- Owner's gateway: `herald-ai-gateway` in the Poxt account (a039c203027ee73c5bf790efd509e879). Owner's token copy also in Memophant vendor credentials (`cloudflare-poxt` / `herald-ai-gateway-token`).
- Cloudflare answers 403 "error code: 1010" (bot filter) to a scripted default User-Agent — the client sends an explicit User-Agent.

## Code map
- HeraldKit/Sources/HeraldKit/AI: `AIGatewayClient` (complete / testConnection); `EmailClassifier.classify(_:candidates:)` (unknown/none tag → nil; no JSON object → `.malformedResponse`); `ClassificationEngine` actor, one per account graph, owned by `MailViewModel.classification`.
- Herald/Support/AIGatewaySettings.swift: UserDefaults `aiGateway.accountID/gatewayID/model`; model stored bare (`@cf/...`), `providerModel(for:)` is the ONLY place `workers-ai/` is prefixed; `configuration(in:)`, `isConfigured(in:secrets:)`. Page `AIGatewaySettingsPage` + testable `AIGatewaySettingsModel`; route `SettingsRoute.aiGateway`; privacy text `PrivacySettingsPane.classificationDisclosure`.
- Herald/Support/WorkflowPreferences.swift: keys `workflow.<escAcct>.<escDomain>.{classify,enabledAt,labels}`; `labels` = `[labelID: {included, description}]`. `setEnabled(true)` stamps `enabledAt` only on off→on. `classificationRules(...)` → nil when off, `[]` when nothing usable (drops deleted labels, blank descriptions). Purged on sign-out; no per-domain purge (matches DomainPreferences). Labels are workspace-wide and cannot be created via the Mail API.
- Herald/Support/ClassificationSupport.swift: `ClassificationContextBuilder.context(...)` per pass (nil when no domain has rules or the gateway is unconfigured; Keychain read last); `WorkflowAttemptLog`.
- Herald/Views/Settings/SettingsWorkflowsPage.swift: toggle, gateway-missing row, pause banner + Resume, setup warning, tag rows, "Recent activity".

## Pipeline
- `MailViewModel.classifyNewMail` (right after `notifyNewMail`, per non-bootstrap `.changed`) → `engine.handle` decides with the pure rules (`messageEligibility`, `eligibility(...)`, `isFirstInbound`, ties by id) against the CACHE (`MailStore.threadHasLabels`, thread messages) and queues; never waits on a model. Memo claim has no await between re-check and enqueue.
- One drain task, serial: pause → hourly cap (60 model calls / rolling hour / account) → SERVER re-check → body → model → cache re-check (`.labelledMeanwhile`) → `MailActionService.setLabel(onConversation:)`.
- Server re-check: `APIThreadSource` = `GET /api/v1/messages/{id}/thread`; the app's `HQBaseAPIClient` sends `includeLabels=true` and MessageDetail decodes `labels` via its MessageSummary half. `ClassificationEngine.serverSkipReason` → `.threadLabelled` (any label on any message) or `.notFirstInbound` (earlier inbound the cache lacked), before any spend. Read failure → `.failed("threadCheck")`, retried after backoff.
- Body: `CachedOrFetchedBodySource` (cached sidecar text, else `GET /messages/{id}`; never writes the sidecar; snippet fallback).
- Pause: gateway-level errors (`isGatewayLevel`: unauthorized, insufficientCredits, modelNotAllowed, blocked, missingToken, invalidConfiguration) pause once → `MailViewModel.classificationPause` → banner. Resumes via the Resume button, a changed account/gateway/model (next pass), or saving/replacing the token (`AIGatewaySettingsModel.onTokenSaved` → `AppEnvironment.resumeClassification()`, all accounts).
- Persistence: attempted thread ids under `workflow.<escAcct>.attempts` (7 days / 500), written just BEFORE the model call (a crash mid-call counts as attempted) and on permanent server skips; withdrawn only on a retryable failure. Messages received > `maxMessageAge` (6 days, < the 7-day log) skip as `.tooOld` (silent): the journal can report an old id as inserted outside a bootstrap (delete then re-delivery), and the log may have forgotten its "none".
- Retention/retry: one queue, bounded `pendingLimit` 100 (oldest dropped + unclaimed). Drain gates before each job: pause (held; re-drained by `resume()`; new mail still queues during a pause), backoff, hourly cap (held; a wake task sleeps until the oldest call leaves the rolling hour). Transient = 429, transport, http 5xx, server thread-check read failure → job back at the head, backoff 60s doubling to 15 min (reset by any model answer), given up (not persisted) after 3 failures. Not a user-visible pause. `.paused`/`.hourlyCap` are no longer recorded per job. Sleeper and clock are injected (`sleep:`/`now:`); tests advance a fake clock.
- Before the write: cache `threadHasLabels`, then the SERVER thread again (`serverThreadHasLabels`; `labels == nil` = unlabelled, documented there — min server 1.3.4) → `.labelledMeanwhile`; a failed read there is `.failed("threadCheck")`, not retried.
- Stop: `stop()` sets a permanent `stopped` flag checked after every await in `handle`, before enqueue, in `startDrainIfNeeded` and in `process`, cancels the wake and awaits the drain. `AccountGraph.stop` awaits it so no write lands behind a sign-out purge.

## Activity log
- Engine ring of 200 `ClassificationRecord`s (date, thread/message/mailbox ids, subject, model, outcome), in memory only. Silent skips (notInbound, notInbox, domainOff, noRules, alreadyAttempted) are not recorded; failure codes from `code(for:)` never carry URL/body/token.
- `setObservers(onActivityChanged:)` pushes `ClassificationActivitySnapshot(version, records)` after each record (replayed on set, like the pause); `MailViewModel.classificationActivityChanged` drops a lower version. Page: `recentActivity` (domain's mailboxes, newest first, 20), wording in `outcomeText/skipText/failureText`.
- Observers are wired by an un-awaited Task in AppEnvironment install (no suspension before the graph is published).

## Eval detail (shabubox, 11 labelled threads)
- qwen3-30b 9/11 (misses: empty-body → none; a Marketing thread whose pitch was not cached); llama-4-scout 9/11 (~0.8s); llama-3.1-8b 7/11; mistral-small-3.1 7/11; granite-4.0-h-micro 3–5/11; gemma-3-12b not enabled on Poxt (403, code 5018).
- Descriptions that worked: Support = help incl. unsupported scanners, how-to, feature/device requests, licensing; Marketing = unsolicited vendor/directory/agency offers; Bug = specific app defect with steps/logs/crash, NOT "doesn't work with my scanner"; General = team/known contacts, thank-yous, internal, test mail.

## Relations
- relates_to [[Herald Label Caching and UI Architecture]]
- relates_to [[Herald Settings Window Architecture]]
