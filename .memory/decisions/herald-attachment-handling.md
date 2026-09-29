---
title: Herald Attachment Handling
type: note
permalink: hqbase-mac/decisions/herald-attachment-handling
tags: [attachments, quicklook, decision, cache]
source_paths: [Herald/Support/AttachmentFile.swift, Herald/Support/AttachmentSaver.swift, Herald/Support/AttachmentBatchSaver.swift, Herald/Design/AttachmentCard.swift, Herald/Compose/ComposeLocalAttachments.swift, Herald/Views/ReadingPaneView.swift, Herald/App/MailViewModel+HTMLAssembly.swift, HeraldKit/Sources/HeraldKit/API/Mapping.swift, HeraldKit/Sources/HeraldKit/Sync/CachedModels.swift]
source_paths_inferred: false
source_sha: 6a0f05d4a79cadf3a4ad461a06e9b3cb26b0b727
created: 2026-09-04
updated: 2026-09-28
reviewed: 2026-09-28
reviewed_by: audit:claude-code (background)
---

P3 of the upstream-1.3.4 adoption (commit b863712) reworked how received attachments are typed, cached, previewed and saved. The rules below are load-bearing; each one replaced a defect that shipped.

## Observations
- [decision] A downloaded attachment's type is `MIMESniffer.resolve(declaredType:data:)`: the server's `Attachment.contentType` is preferred, the magic bytes are the cross-check — a declaration that REFINES the bytes wins (a .docx is a zip; svg is xml), contradicted bytes win (a part labelled image/png whose bytes are %PDF stages as PDF), and `GET /attachments/{id}` gives the generated client no usable Content-Type, so it only sniffs #mime
- [gotcha] Quick Look picks its previewer from the FILENAME EXTENSION alone, so `AttachmentFile.filename` appends the resolved type's extension whenever the name has none OR its extension does not conform to the resolved type (`invoice.dat` + PDF bytes → `invoice.dat.pdf`); the user's name is never discarded, and the save panel proposes the STAGED name so panel and file agree #quicklook
- [decision] Inline-ness is `Attachment.disposition` from the server (1.3.4), never `contentID != nil` — a content ID does not make a part inline, and the old inference hid Content-ID-carrying PDFs from the attachment bar #disposition
- [decision] Attachment METADATA (not bytes) is cached on `CachedMessageBody.attachments`; a failed `GET /messages/{id}` rebuilds a MessageDetail from summary + body sidecar so the bar survives offline — EXCEPT on a decoding failure, which is the server contract breaking and must surface instead of serving stale detail forever #offline
- [gotcha] `substituteInlineImages` matches only QUOTED `src`/`background` attribute values (case-insensitive attribute name, escapedPattern/escapedTemplate); a global string replace rewrote the sender's prose, and an unquoted form cannot be told apart from `src=cid:` sitting inside another attribute without parsing the tag. The staged-file LRU (16) is refcounted: `url(for:pinned:)` pins INSIDE the actor, so eviction cannot delete a file under a live Quick Look panel, a drag (30s grace) or a save #inline

## Attachment cards (redesign v3 V4, commit 984286b)
- [design] `AttachmentCard` (Herald/Design/AttachmentCard.swift) replaced `AttachmentChip` in the reading pane AND compose: 44pt, min 220 / max 320 in `AttachmentFlowLayout` (gap 8), bg fill + 1px line ring, 28pt lineSoft file-type tile (`MailTheme.Symbol.fileType(filename:contentType:)` — EXTENSION wins over content type because servers send octet-stream; content type only for extension-less names), name 12/500 middle-truncated over mono-10 size. Buttons DRAW 24pt (`MailTheme.compactIconButtonDiameter`) but hit area is 28 (`MailTheme.hitTarget`) via outer frame + contentShape. Any `nil` action is not drawn and gets no accessibility action. Card is `.focusable` when it has Quick Look; Space triggers it #attachments
- [decision] Download All = one `NSOpenPanel` folder chooser → `AttachmentBatchSaver.save` fetches each via `AttachmentFile.url(pinned:)`, copies (staged `.uuid.name` then move) with Finder-style de-dup ("name 2.pdf") and quarantine, unpins after each copy, reports partial failure through `actionError` ("could not download N of M: names"). Single Download keeps the save panel (`AttachmentSaver.save(stagedFile:)`, shared `install(_:at:)`). Since eb4725b BOTH panels open in the user's REAL ~/Downloads (`AttachmentSaver.configure(_:proposing:)`, `AttachmentBatchSaver.configure(_:)`, `AttachmentStorage.downloadsDirectory` via getpwuid — FileManager's .downloadsDirectory is the sandbox container's copy) #download-all

## Cache location (eb4725b, 2026-09-28)
- [gotcha] ROOT CAUSE of "Quick Look throws an error": the old temp scratchpad (`<tmp>/com.wizemann.herald/Attachments`) was wiped WHOLESALE on the first stage of every process launch, and the unit-test host IS the Debug app (same bundle id → same sandbox container). Any test run (agents run them constantly) or second copy deleted the file under a live Quick Look panel. Reproduced live: Q3 Proposal.pdf staged at 16:33:13 was gone seconds later, replaced by test files a1.txt/a5.txt/big.bin. NEVER wipe a shared cache directory wholesale #quicklook
- [decision] Received attachments cache at `Application Support/<bundle id>/Attachments/<account id>/<attachment id>/<real filename+ext>` (`AttachmentStorage.attachments`); keys are `account/attachment`; `url(for:accountID:using:pinned:)`, `pin/unpin(_:accountID:)`. Written via a hidden `.partial` folder then renamed; reused across launches. LRU 16 + pinning unchanged. `AttachmentFile(root:)` is injectable — tests MUST pass a temp root so they never touch the app's cache #cache
- [decision] Cleanup is age-based only: once per launch, entries untouched for `AttachmentStorage.staleAge` (2 days) are pruned; the legacy temp dir is removed once. Sign-out calls `AttachmentFile.shared.removeAccount(accountID)`. Compose copies + pasted images live in `Application Support/<bundle id>/Compose/<uuid>/` (`AttachmentScratchpad`), deleted by their owner, same stale prune #cache
- [decision] Compose has no GET for draft attachments, so each upload is COPIED into `AttachmentScratchpad` (Application Support/<bundle id>/Compose) while its security scope is held (`ComposeLocalAttachments`, keyed by the one new attachment id; ambiguous diffs record nothing). No scope outlives the upload. Copies are deleted on Remove (prune) and on window close (`releaseLocalFiles()` from ComposeWindowRoot.onDisappear); a late upload after close discards its copy. Reopened drafts show Remove only #compose
- [gotcha] A `ScrollView` capping the card flow takes every point offered (ViewThatFits + maxHeight left a big gap under the header): measure the flow with `onGeometryChange` and frame the ScrollView to `min(contentHeight, cap)` #layout
- [procedure] Visual audit with attachments: add `-HeraldFakeAttachments YES` to the `-HeraldUITest twoAccounts` launch; every inbound message then carries 3 fixture attachments (ids `<msg>-att<i>`, bytes served octet-stream from `GET /attachments/{id}`). Off by default so UI-suite data is unchanged #visual-audit


## Relations
- relates_to [[Herald Sync Model]]
- relates_to [[HQBase Mail API v1 Contract]]
- relates_to [[Herald Error Handling and Security Rules]]
