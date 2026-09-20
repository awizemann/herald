---
title: Herald Attachment Handling
type: note
permalink: hqbase-mac/decisions/herald-attachment-handling
tags: [attachments, quicklook, decision, cache]
source_paths: [Herald/Support/AttachmentFile.swift, Herald/Support/AttachmentSaver.swift, Herald/Views/ReadingPaneView.swift, Herald/App/MailViewModel+HTMLAssembly.swift, HeraldKit/Sources/HeraldKit/API/Mapping.swift, HeraldKit/Sources/HeraldKit/Sync/CachedModels.swift]
source_paths_inferred: false
source_sha: 7e5eb159db68edaac988bfd21ae27c5ae670639d
created: 2026-09-04
updated: 2026-09-04
reviewed: 2026-09-09
reviewed_by: audit:claude-code (background)
---

P3 of the upstream-1.3.4 adoption (commit b863712) reworked how received attachments are typed, cached, previewed and saved. The rules below are load-bearing; each one replaced a defect that shipped.

## Observations
- [decision] A downloaded attachment's type is `MIMESniffer.resolve(declaredType:data:)`: the server's `Attachment.contentType` is preferred, the magic bytes are the cross-check — a declaration that REFINES the bytes wins (a .docx is a zip; svg is xml), contradicted bytes win (a part labelled image/png whose bytes are %PDF stages as PDF), and `GET /attachments/{id}` gives the generated client no usable Content-Type, so it only sniffs #mime
- [gotcha] Quick Look picks its previewer from the FILENAME EXTENSION alone, so `AttachmentFile.filename` appends the resolved type's extension whenever the name has none OR its extension does not conform to the resolved type (`invoice.dat` + PDF bytes → `invoice.dat.pdf`); the user's name is never discarded, and the save panel proposes the STAGED name so panel and file agree #quicklook
- [decision] Inline-ness is `Attachment.disposition` from the server (1.3.4), never `contentID != nil` — a content ID does not make a part inline, and the old inference hid Content-ID-carrying PDFs from the attachment bar #disposition
- [decision] Attachment METADATA (not bytes) is cached on `CachedMessageBody.attachments`; a failed `GET /messages/{id}` rebuilds a MessageDetail from summary + body sidecar so the bar survives offline — EXCEPT on a decoding failure, which is the server contract breaking and must surface instead of serving stale detail forever #offline
- [gotcha] `substituteInlineImages` matches only QUOTED `src`/`background` attribute values (case-insensitive attribute name, escapedPattern/escapedTemplate); a global string replace rewrote the sender's prose, and an unquoted form cannot be told apart from `src=cid:` sitting inside another attribute without parsing the tag. The staged-file LRU (16) is refcounted: `url(for:pinned:)` pins INSIDE the actor, so eviction cannot delete a file under a live Quick Look panel, a drag (30s grace) or a save #inline

## Relations
- relates_to [[Herald Sync Model]]
- relates_to [[HQBase Mail API v1 Contract]]
- relates_to [[Herald Error Handling and Security Rules]]
