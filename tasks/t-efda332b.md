---
id: t-efda332b
title: Fix refresh race: a refresh finishing after re-auth overwrites the new grant
status: done
added: 2026-09-26
priority: high
---

## Description

Found by U1 reviewer (and P9a reviewer as "older race"): AccountTokenProvider.performRefresh writes refreshed tokens unconditionally, so a refresh in flight across a re-auth (same or other process) overwrites the fresh grant with tokens of the dead family → account re-latches right after sign-in. Fix with compare-and-set: persist only if the store still holds the refresh token that was spent. Reproducible now via the UI-test harness (deadSession140).

## Plan



## Artifacts



