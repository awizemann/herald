---
id: t-7cb91eec
title: A1: cache integrity — decode-failure store-nuke trigger, deleteMissingMessages cascade
status: done
added: 2026-09-04
priority: high
---

## Description

From documents/reports/full-surface-audit-2026-09-04.md (data integrity §): (1) fetch-time DecodingError on Codable-blob columns never triggers the rebuildable-cache recovery — detect in MailStore and route to the store-nuke path; convention: new fields on blob DTOs must be optional/defaulted. (2) deleteMissingMessages (MailStore+Tombstoning.swift:14-35) must cascade body sidecars + label assignments + pending fences like deleteMessage does. (3) Comment the accepted sweep-inserts-unknown-ids behavior.

## Plan

DONE on feat/upstream-134-adoption, commit fa1930e (HeraldKit only).

1. Decode-failure recovery — design changed after MEASURING the failure. SwiftData
   decodes a Codable column with `try!` (DefaultStore.swift:2393), so a shape change
   is a process-fatal trap inside fetch, NOT a catchable error: no typed error and no
   route to the container's delete-and-retry valve is reachable. Verified in-process
   both ways (missing key -> keyNotFound; garbage bytes -> dataCorrupted). Fix is
   therefore structural: total `init(from:)` on Attachment / DraftAttachment /
   MailboxAddress / SignatureSnapshot (explicit CodingKeys, every field defaulted).
   A prototype error-classify-and-purge valve was written, proven unreachable, and
   deleted rather than left as dead code. Convention documented on all four DTOs and
   the limit of the open() valve documented on MailStoreContainer.
2. deleteMissingMessages now cascades: body sidecars, label assignments, pending fences.
3. replaceAssignments' accepted sweep-inserts-unknown-ids behaviour commented,
   incl. the consequence for label badges.</plan>
<parameter name="artifacts">- HeraldKit/Sources/HeraldKit/Model/{Message,Draft,Mailbox,Signature}.swift — total decoders + convention
- HeraldKit/Sources/HeraldKit/Sync/MailStoreContainer.swift — limit of the open() valve
- HeraldKit/Sources/HeraldKit/Sync/MailStore+Tombstoning.swift — cascade
- HeraldKit/Sources/HeraldKit/Sync/MailStore+Labels.swift — accepted-behaviour comment
- HeraldKit/Tests/HeraldKitTests/Sync/CacheIntegrityTests.swift — 5 tests
- memory: decisions/Herald Sync Model.md, "Update (2026-09-04 — A1 cache integrity)"

Tests: HeraldKit 277 pass; app suite 242 pass; build-detached.sh BUILD SUCCEEDED.
Cascade test verified discriminating (all 3 orphan classes fail without the fix);
blob test verified discriminating (crashes the test process without the fix).

## Artifacts

- HeraldKit/Sources/HeraldKit/Model/{Message,Draft,Mailbox,Signature}.swift — total decoders + convention
- HeraldKit/Sources/HeraldKit/Sync/MailStoreContainer.swift — limit of the open() valve
- HeraldKit/Sources/HeraldKit/Sync/MailStore+Tombstoning.swift — cascade
- HeraldKit/Sources/HeraldKit/Sync/MailStore+Labels.swift — accepted-behaviour comment
- HeraldKit/Tests/HeraldKitTests/Sync/CacheIntegrityTests.swift — 5 tests
- memory: decisions/Herald Sync Model.md, "Update (2026-09-04 — A1 cache integrity)"

Tests: HeraldKit 277 pass; app suite 242 pass; build-detached.sh BUILD SUCCEEDED.
Cascade test verified discriminating (all 3 orphan classes fail without the fix);
blob test verified discriminating (crashes the test process without the fix).

