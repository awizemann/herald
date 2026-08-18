---
title: Upstream Delta Sync Contract (approved)
type: note
permalink: hqbase-mac/roadmap/upstream-delta-sync-contract-approved
tags:
- upstream
- sync
- contract
---

bermanto approved delta sync on 2026-08-17 (https://github.com/HQBase/hqbase/issues/11#issuecomment-5310381797)
as TWO independent, ordered PRs, each with a spec-first companion PR in HQBase/hqbase-site.
This note is the contract Herald must build against; the comment is authoritative on details.

## Observations
- [decision] PR-A "pagination" — GET /api/v1/messages gains `limit` (1–100, default 100) and an opaque VERSIONED `cursor` over (activity_at, id); order `activity_at DESC, id DESC` (activity_at = COALESCE(received_at, sent_at, created_at)); fetch limit+1; body STAYS a JSON array; RFC 8288 `Link: <…>; rel="next"` preserving mailboxId/folder/search/limit, absent on the last page; malformed limit/cursor → stable 400; cursor never weakens mailbox-access filtering; add an activity index + fresh/upgrade migration coverage if the plan still sorts; NO updatedSince/changes/journal in this PR #pr-a
- [decision] PR-B "changes" — dedicated `GET /api/v1/changes` (mail:read); durable `message_changes` journal (INTEGER PRIMARY KEY AUTOINCREMENT sequence, message_id, mailbox_id, kind upsert|delete, changed_at; NO FK to messages) written by DB TRIGGERS on message insert/update/delete; ordering key = sequence only, in an opaque versioned cursor; `sequence > cursor` ASC, limit+1; NO folder/search filters; JSON envelope `{changes:[{type:"upsert",message:MessageSummary}|{type:"delete",messageId,mailboxId}], nextCursor, hasMore}`; mailbox access applied per entry (tombstones authorized by stored mailbox_id); no cursor = CHECKPOINT (no history, current high-water cursor); cycle captures a high-water sequence, page cursors carry it, final page advances nextCursor to it; journal rows are NOT pruned in v1 (future pruning must 410 CHANGE_CURSOR_EXPIRED) #pr-b
- [rule] Client protocol (Herald): re-list /mailboxes before each sync cycle (purge unreadable mailboxes' cache; full bootstrap for newly readable); bootstrap = checkpoint → paginate full message list → consume changes after checkpoint until hasMore=false; thereafter poll /changes with the stored cursor #client
- [todo] Test matrix required by the author — PR-A: equal activity timestamps, page boundaries, no dup/missing rows, filter preservation, access filtering, invalid values, no Link on last page, OpenAPI+Postman regenerated. PR-B: fresh+upgrade migration tests; inserts, single updates, >100 bulk updates sharing one timestamp, two rapid updates to one message, folder moves, retention tombstones, cursor round-trips, high-water paging, malformed cursors, mailbox auth, grant/revocation, response-field safety (no R2 keys); staging E2E before release #tests
- [fact] Order: PR-A (+ hqbase-site spec PR) → merge → PR-B (+ spec PR) → Herald swaps SyncEngine re-list for checkpoint+changes and drops the 100-cap guard #order

## Relations
- relates_to [[Upstream PR Queue]]
- relates_to [[Herald Sync Model]]
- relates_to [[HQBase Mail API v1 Contract]]
