---
id: t-bdd6b056
title: 1.4 U2: labels from includeLabels rows + slow reconciliation sweep
status: done
added: 2026-09-19
priority: high
---

## Description

SyncEngine passes includeLabels=true; MailStore writes membership from every upserted row (journal, listings, thread, actions); per-label sweep demoted to reconciliation: run on labels wake frame / label-list change and on a long timer (~30 min), never the 120s cadence. Rows without a labels field (server <1.4.2) keep the old behaviour. Conversation label union computed locally must agree with LabelAssignmentResult. Update memory (labels section, SyncEngine cadence docs). Depends on U1.

## Plan



## Artifacts

Branch `worktree-agent-a668aebb91fca6c87`, commit 77f6614 (on top of 45b72a9).

Files: Herald/App/{AppEnvironment,MailViewModel,MailViewModel+Labels}.swift,
HeraldKit/Sources/HeraldKit/Sync/{MailStore,MailStore+Labels,SyncEngine,CachedModels}.swift,
plus tests (HeraldKit LabelSyncTests + fixtures, HeraldTests LabelsTests + fixtures).

Tests: HeraldKit 318 -> 325, app-hosted 255 -> 256, both green.

Live-verified against the local 1.4.2 instance: a label assign/remove is one
journal upsert each, and `/changes?includeLabels=true` carries `labels`
(populated, then `[]`); without the parameter the key is absent.

Memory: edited "Herald Sync Model", "Herald Label Caching and UI Architecture",
"HQBase Mail API v1 Contract".

NOT verified: Herald itself running against 1.4.2 (needs a GUI sign-in) — left
for U5's dogfood.

