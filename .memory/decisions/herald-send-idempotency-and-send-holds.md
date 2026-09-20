---
title: Herald Send Idempotency and SEND_* Holds
type: note
permalink: hqbase-mac/decisions/herald-send-idempotency-and-send-holds
tags: [herald, compose, outbox, upstream-140, idempotency]
source_paths: [HeraldKit/Sources/HeraldKit/Compose/ComposeDraft.swift, HeraldKit/Sources/HeraldKit/Compose/OutboxService.swift, HeraldKit/Sources/HeraldKit/Compose/OutboxError.swift, HeraldKit/Sources/HeraldKit/Compose/ComposePrefill.swift, Herald/Compose/ComposeViewModel.swift]
source_paths_inferred: false
source_sha: 45b72a904cd318823759f2ad52f64e5f1312eb1d
created: 2026-09-19
updated: 2026-09-19
---

How Herald adopted upstream 1.4.0's send `idempotencyKey` and the two 503 send
outcomes (U3, task t-fe56989b). Server semantics live in the API contract note;
this records the CLIENT's rotation rule and the compose window's behaviour.
`ComposeDraft.sendAttemptKey` is a UUID minted when the window opens, carried on
send/reply/forward, and excluded from `hasSameEditableContent`. Forward is the
case that mattered most: `POST /forward` has no `draftId`, so the key was its
only possible retry identity.

## Observations
- [decision] The send key rotates in exactly TWO places: after a successful send (so a reused compose window's next message is not deduped away) and on `SEND_KEY_CONFLICT`, followed by exactly one automatic retry — never a loop #idempotency
- [decision] It deliberately does NOT rotate when the user edits after a failed send, though that edit provokes the 409: the server hashes the REQUEST PAYLOAD it received (`canonicalJson({kind, input})` in upstream `send/operations.ts`, verified 2026-09-19 — NOT the assembled mail), so a client-side predicate is possible but would be a second definition of "same message" that must track every hashed field (recipients, subject, text, attachment ids, signature selection, draft id) and drift when upstream adds one — letting the 409 be the authority is exact and costs one extra round trip #idempotency
- [gotcha] `OutboxService.send` returns a `SendReceipt` (message + rotated draft); `ComposeViewModel` takes ONLY the key via `adoptSendAttemptKey(from:)` — assigning the receipt's whole draft would revert anything typed during the round trip, the same data-loss bug `adoptServerState(from:sent:)` exists to avoid #compose
- [decision] Both 503s map to `OutboxError.sendOnHold(SendHold)` and are NEVER retried: `.recovering` (SEND_RECOVERY_UNAVAILABLE, mail already accepted) disables Send for the window's lifetime; `.storageNotReady` (nothing accepted, server mid-update) lifts on any edit, and the unchanged key makes even a too-early retry safe #outbox
- [fact] Reply prefill fills `to` from `MessageDetail.replyTo` when non-empty (Reply semantics: it REPLACES the sender, reply-all still appends the original `to`); `nil` and `[]` both fall back to the sender, and it is display parity because the server already routes there when `to` is omitted #compose

## Relations
- relates_to [[HQBase Mail API v1 Contract]]
- relates_to [[Herald Signature Handling]]


## Hold UX (2026-09-19 — audit F2 C3)

A hold that the window will not explain is worse than one it refuses loudly. The
audit found the held Send was a bare `.disabled` button: VoiceOver said "Send,
dimmed" and nothing else, and ⌘⇧D — the documented escape hatch that was supposed
to re-announce the reason — did nothing at all, because SwiftUI withdraws a
disabled control's key equivalent along with the control. The view-model's
"re-announce" branch was dead code.

- [decision] The hold's own sentence (`OutboxError.sendOnHold(hold).localizedDescription`, via `ComposeViewModel.sendHoldReason`) drives BOTH the Send button's `.help` and its `.accessibilityHint`. One `nonisolated static` source for what is drawn and what is spoken, assertable without a rendered window — the `ReauthBanner.message`/`announcement` pattern #a11y
- [decision] ⌘⇧D moved off the Send button onto a never-disabled `.opacity(0)` proxy (`ComposeView.sendShortcut`), so the shortcut always reaches `send()`, which refuses and re-announces. `isBusy` still disables the proxy — a send in flight is a different thing from one the server has forbidden. The button keeps the `.disabled` appearance, which is the correct affordance; only the key equivalent is elsewhere, so `.help` now spells "⌘⇧D" out #compose
- [gotcha] Re-announcing could not ride on `status`: its `didSet` guards on a CHANGE, and the status is ALREADY that failure by the second press, so presses two onward were silent. `announcement` is now paired with `announcementCount`, bumped on every announcement including a repeat, and the window observes the COUNTER. Two bumps inside one synchronous call coalesce into one `onChange`, so the belt-and-braces re-announce cannot speak twice #a11y
- [fact] The refusal itself is unchanged and still proven: a held send is never POSTed a second time, however it is invoked (`ComposeViewModelTests.everyBlockedSendAttemptReAnnouncesTheReason` asserts `sendCount == 1` across three ⌘⇧D presses). Making the shortcut reachable must not make the SEND reachable #outbox
