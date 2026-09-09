---
id: t-f461fcf6
title: P5: compose quoted-thread preview (display-only, never concatenated into bodyText)
status: done
added: 2026-09-04
---

## Description

ComposePrefill.quotedBody/quoteHeader are dead code; render collapsed read-only quote under TextEditor (ComposeWindow.swift:78-84), plumb via ComposeContext.makeDraft → ComposeViewModel.quotedPreview. Concatenating would double the quote on send (server appends). Plan §D.

## Plan

Added `ComposePrefill.quotedPreview(of:mode:locale:)` (reply/reply-all → existing quotedBody attribution+quote; forward → raw textBody; new → nil). Exposed via `ComposeContext.quotedPreview` and stored on `ComposeViewModel.quotedPreview` (display-only, set once at init from context, never written into `draft.body`/`bodyText`). Rendered in ComposeWindow.swift as a collapsed-by-default DisclosureGroup below the TextEditor and above the attachment bar, using MailTheme.Spacing/Radius tokens, selectable text, VoiceOver label.

## Artifacts

Commit 4d1a58d on feat/upstream-134-adoption. Tests: HeraldKit swift test (217/217 pass, incl. new ComposePrefillTests.quotedPreview); xcodebuild test Herald scheme (all pass, incl. new ComposeViewModelTests.quotedPreviewIsDisplayOnlyAndNeverJoinsTheOutgoingBody asserting the preview never reaches outbox.lastSent for both reply and forward paths); ./scripts/build-detached.sh succeeded and launched. Adversarial audit (subagent): no blockers/majors; 4 minors — reopened drafts (kind .draft) show no preview since ComposeContext.message is only set for fresh reply/forward requests (deferred, out of scope per plan §D which covers fresh reply/reply-all/forward only); DisclosureGroup label re-derives forward-vs-reply from draft.mode instead of reusing kind (harmless duplication, not fixed); static accessibilityLabel may mask expand/collapse state (left as-is, acceptable); test coverage gap on reply send path — FIXED by adding a reply-path send() assertion alongside the forward one.

