---
title: Herald Wake Socket Architecture
type: note
permalink: hqbase-mac/decisions/herald-wake-socket-architecture
tags: [decision, sync, websocket, upstream-1.3.4]
source_paths: [HeraldKit/Sources/HeraldKit/Sync/MailEventSocket.swift, HeraldKit/Sources/HeraldKit/Sync/URLSessionMailEventChannel.swift, HeraldKit/Sources/HeraldKit/Sync/SyncEngine.swift, Herald/App/MailViewModel.swift, Herald/App/AppEnvironment.swift]
source_paths_inferred: false
source_sha: 7e5eb159db68edaac988bfd21ae27c5ae670639d
created: 2026-09-04
updated: 2026-09-04
reviewed: 2026-09-09
reviewed_by: audit:claude-code (background)
---

How Herald consumes upstream 1.3.4's `GET /api/v1/events` wake socket (P6, task t-063dbcb0). The server's verified semantics live in [[HQBase Mail API v1 Contract]] under "#events-*"; this note is the CLIENT's shape and the reasoning behind it.

Three types, each with one job. `URLSessionMailEventChannels` opens one `URLSessionWebSocketTask` per connection (its own `URLSession` per channel, so the delegate maps 1:1 onto the task and `invalidateAndCancel()` on close is unambiguous) and translates handshake rejections read off `task.response` into `MailEventChannelError`. `MailEventSocket` (an actor) owns the reconnect policy and turns text frames into `MailEventSignal`s. `MailViewModel.handleWakeSignal` maps a signal onto the right refresh. Nothing about the socket ever writes to the cache — a frame carries no data, so the only correct response is to go and read.

## Observations
- [decision] The socket ACCELERATES the poll, never replaces it: `SyncEngine.setWakeSocketConnected(true)` stretches the interval (active 15s→120s, idle 60s→300s) and losing the socket WAKES the loop so the tight cadence resumes immediately instead of waiting out a stretched sleep. Frames are wake-only with no replay, so a client that stopped polling diverges silently the first time one is dropped #floor
- [decision] Topic→refresh is not one-to-one with the topic names: `messages` and `mailboxes` → `refreshNow()`; `drafts` → `refreshDraftsNow()`; `labels` → `refreshLabelsNow()`; and a RECONNECT signals all three, because nothing is replayed across a gap. A `messages` frame deliberately does NOT sweep labels even though label assignment publishes on that topic — that would put one request per label behind every read and star in the workspace #routing
- [decision] Reconnect policy: a connection that lasted ≥60s ended because its 10-minute lease did (close 1008), which is the NORMAL case — failure count resets and it reconnects after a jittered base delay. Only a SHORT-lived or refused connection increments the count (exponential, capped at 120s, half-fixed/half-jittered so a fleet whose leases end together does not stampede) #backoff
- [gotcha] A watchdog rebuilds a connection that has received nothing for 11 minutes. A half-open TCP connection (lid closed, network switched) leaves `receive()` parked with no close and no error — and a socket the client still believes in keeps the poll STRETCHED, so a silent socket would silently slow mail down. The server closes at 10 minutes, so silence past that is never normal #watchdog
- [decision] 401 at upgrade → refresh the token that was rejected → retry ONCE → escalate to the same `needsReauth` transition the sync loop uses and STOP the loop. Both halves share one `AccountTokenProvider`, so the rotating refresh grant is never spent twice. The socket's lifetime follows app activation (started/stopped by `MailViewModel.setActive`) and `AccountGraph.stop()` closes it BEFORE the engine — a leaked socket would count against the server's 3-per-user limit and evict the live one #lifecycle

## Relations
- relates_to [[Herald Sync Model]]
- relates_to [[HQBase Mail API v1 Contract]]
- relates_to [[Herald Architecture]]


## Audit findings (fresh-eyes pass, all fixed before commit)

Five defects the first implementation shipped with, kept here because each one is a trap the NEXT socket-shaped feature can fall into:

- [gotcha] `URLSessionWebSocketTask.receive()` is a bridged completion-handler call and does NOT observe Task cancellation. A `withThrowingTaskGroup` racing it against a timeout therefore never returns — `cancelAll()` cannot free the receive child, and the group waits for it. The watchdog was dead code on exactly the half-open connection it exists for. It now CLOSES the channel (that is what fails a pending receive), and `MailEventChannel.receive()` documents that close is the only escape #cancellation
- [gotcha] The test fake was cancellation-aware where the real channel is not, so the watchdog test passed against a watchdog that could never fire. A fake that is easier to escape than the real thing proves nothing — the fake now parks until `close()`, like the real one #fakes
- [gotcha] `URLSession` holds a STRONG reference to its delegate until invalidated. Dropping a channel whose handshake failed leaked a session + delegate per attempt, on the one path that repeats forever by design (a server that is down). `open()` now closes the channel on any throw #leaks
- [gotcha] `stop()` suspends on `await task?.value`, which RELEASES the actor: a `start()` arriving in that window (resign-active immediately followed by become-active) either started a SECOND loop or was silently dropped. Now a run generation invalidates the outgoing loop's writes, and a start that lands mid-teardown is handed to the stop and applied when it finishes #teardown-race
- [gotcha] Callbacks fired into detached `Task`s have NO ordering: a connected/disconnected pair could reach `SyncEngine` backwards, and since its flag is a latch the poll would stay stretched behind a dead socket forever. All three callbacks are now `async` and awaited from inside the actor #ordering
- [decision] A rejected change cursor now re-bootstraps at most once per 5 minutes per account (`SyncEngine.defaultRebootstrapCooldown`). The recovery looks like a SUCCESSFUL pass — full re-listing, bootstrap-flagged so notifications stay silent, no failure counted — so a server that keeps rejecting the cursor it issued was an invisible, permanent, full-listing-per-tick loop #rebootstrap-cooldown
