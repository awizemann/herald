---
id: t-063dbcb0
title: P6: adopt GET /events wake WebSocket + verify /changes journal sync live; drafts/changes for drafts cache
status: done
added: 2026-09-04
---

## Description

Wake-only WS (topics messages|drafts|mailboxes|labels, 10-min lease) thins the poll loop. Folds in t-8a1c0051 (verify checkpoint+/changes, retire 100-cap guard) now that 1.3.4 ships #35/#37. Precondition: Alan's instance upgraded to 1.3.x.

## Plan



## Artifacts

P6 implemented on branch feat/upstream-134-adoption.

VERIFIED LIVE (localhost:8787, upstream v1.3.4):
- events upgrade = plain GET + `Authorization: Bearer` header, no subprotocol, no token query param; cookie sessions also work but only with a matching Origin.
- frames exactly `{"type":"changed","topic":…}`, one per mutation, no coalescing.
- LABEL ASSIGNMENT publishes topic `messages`, not `labels`; the `labels` topic is label CRUD only.
- lease measured at exactly 600.004s, close code 1008 "Reconnect to renew authentication."
- 401 at upgrade is an ordinary pre-101 HTTP response with a Bearer challenge.
- change journal: checkpoint → mutation → one upsert entry → hasMore:false, exercised end to end.
- `GET /messages?limit=2` returns a real `Link: rel="next"` — pagination is genuinely present at 1.3.4.

CODE:
- new `MailEventSocket` (actor: reconnect/backoff/jitter, lease-aware, 11-min silence watchdog, one-refresh 401 rule) and `URLSessionMailEventChannels` (URLSessionWebSocketTask, handshake rejections read off `task.response`).
- `SyncEngine.setWakeSocketConnected` stretches the poll (15s→120s / 60s→300s) and wakes the loop the moment the socket dies. Polling is never stopped.
- `MailViewModel.handleWakeSignal` routes topics; the socket's lifetime follows app activation; `AccountGraph.stop()` closes it before the engine.
- DEFECT FOUND AND FIXED while verifying the journal: a foreign/out-of-range change cursor answers 400 INVALID_CHANGE_CURSOR (not 410), which Herald treated as a generic failure — permanent, since the cursor is persisted. Now mapped to `.cursorExpired` → re-bootstrap.

t-8a1c0051's verification is folded in and satisfied; the 100-cap guard is reconciled (kept, now legacy-server-only) in the Herald Sync Model note.
DEFERRED: GET /drafts/changes adoption → t-85cfa329, with the scoping written out.

Tests: HeraldKit 269 pass; app target 237 pass; build-detached.sh BUILD SUCCEEDED. New: MailEventSocketTests, PollStretchTests, WakeSocketRoutingTests, LiveEventSocketTests (env-gated, run green against localhost), extended ChangesAPITests.

