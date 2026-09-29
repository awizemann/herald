---
title: Herald AI Classification via Cloudflare AI Gateway
type: note
permalink: hqbase-mac/decisions/herald-ai-classification-via-cloudflare-ai-gateway
tags: [ai, workflows, classification]
source_paths: [Herald/Views/Settings/SettingsView.swift, Herald/App/SettingsRoute.swift]
source_paths_inferred: false
source_sha: 2bfa6bee79e5baf669c80ee8cf23b74d74feaead
created: 2026-09-29
updated: 2026-09-29
---

Workflows → email classification (exploration 2026-09-29, nothing built yet).

## Observations
- [decision] Transport: Cloudflare AI Gateway `herald-ai-gateway` in the Poxt account (a039c203027ee73c5bf790efd509e879), OpenAI-compatible `https://gateway.ai.cloudflare.com/v1/{account}/{gateway}/compat/chat/completions`, auth ONLY `cf-aig-authorization: Bearer <gateway token>` — no Cloudflare API token, no provider keys. Verified working for Workers AI models (`workers-ai/@cf/...`); third-party models (`anthropic/...`) need AI Gateway credits (HTTP 402, code 2021 without them) #ai
- [gotcha] Cloudflare returns 403 "error code: 1010" (bot filter) for Python-urllib's default User-Agent — Herald's client must send an explicit User-Agent #ai
- [decision] Gateway token lives in Keychain (service `cloudflare-poxt`, account `herald-ai-gateway-token`) and in Memophant vendor credentials; never in chat/files #security
- [decision] Classify each THREAD once: only the first inbound message of a thread without any tag is sent to the model; a thread with any tag (model, human, other device) is never re-classified. Bug report followed by chit-chat must not flip #workflow
- [decision] New mail only by default; no backfill #workflow
- [decision] Labels are workspace-wide and cannot be created via the Mail API; per-domain workflow config in Herald picks eligible labels and supplies a one-line description per label (HQBase labels have no description) #labels
- [gotcha] Model self-reported confidence is useless (always 0.8–0.95, even when wrong) — do not gate on it #ai
- [gotcha] First eval (shabubox, 11 labeled threads): granite-4.0-h-micro 5/11, qwen3-30b-a3b-fp8 5/11 (~0.45s/call). Main error was Support vs Bug on user hardware/scan problems — the tag descriptions overlap, which dominates model choice #eval

## Relations
- relates_to [[Herald Label Caching and UI Architecture]]
- relates_to [[Herald Settings Window Architecture]]
