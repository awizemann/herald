---
title: Herald Signature Handling
type: note
permalink: hqbase-mac/decisions/herald-signature-handling
tags: [herald, compose, signatures, upstream-134]
source_paths: [HeraldKit/Sources/HeraldKit/Model/Signature.swift, HeraldKit/Sources/HeraldKit/Compose/ComposeDraft.swift, HeraldKit/Sources/HeraldKit/Compose/OutboxService.swift, Herald/Compose/ComposeViewModel.swift, Herald/Compose/ComposeWindow.swift, HeraldKit/Sources/HeraldAPI/openapi.json]
source_paths_inferred: false
source_sha: 3d99c49fde000552ed08dab90a1d54a86d74cb0b
created: 2026-09-04
updated: 2026-09-04
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
