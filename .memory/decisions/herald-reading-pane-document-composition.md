---
title: Herald Reading-Pane Document Composition
type: note
permalink: hqbase-mac/decisions/herald-reading-pane-document-composition
tags: [reading-pane, html, webkit, security, design]
source_paths: [Herald/App/MailViewModel+HTMLAssembly.swift, Herald/App/MailViewModel.swift, Herald/Design/MailTheme.swift, HeraldKit/Sources/HeraldKit/Model/Message.swift, HeraldTests/MessageBodyCompositionTests.swift]
source_paths_inferred: false
source_sha: 5097194ad8a505144220b87af67b1b89a863e718
created: 2026-09-04
updated: 2026-09-27
reviewed: 2026-09-27
reviewed_by: audit:claude-code (background)
---

P4 (task t-d60a1704, commit c55fd8f) settled how the reading pane turns a `MessageHTML` into one document. Upstream 1.3.4 splits a body into three authored fragments (`html`, `quotedHtml`, `afterQuotedHtml`) plus per-fragment remote-image flags; Herald rendered only the first, so text written BELOW a quote was silently lost.

`MailViewModel.composeBody` is the single assembly point (nonisolated, unit-tested without a web view): main section, `<details>` quoted history closed by default, then the after-quote section. JavaScript stays disabled, so the collapse MUST be a native `<details>` — anything script-driven is unavailable, and that constraint also still blocks the stacked-thread view (deferred).

## Observations
- [decision] The pane composes html + collapsed <details> quotedHTML + afterQuotedHTML in `MailViewModel.composeBody`; `<details>` is the ONLY collapse affordance available because `allowsContentJavaScript = false` (which is also why the stacked-thread view stays deferred) #reading-pane
- [gotcha] The body CACHE column stores the COMPOSED fragment, not `payload.html` — the sidecar has one HTML column, so caching the raw main fragment would drop the quote and the after-quote text on every offline read; the trade-off is that presentation markup (class names, the English "Show quoted history") is baked into cache rows, which are rebuildable #cache
- [rule] Fragments are stripped of their own `<details>`/`<summary>` tags before splicing: not XSS (script off, CSP `default-src 'none'`) but sender content must not forge Herald's own chrome #security
- [rule] Plain-text linkification escapes on the RAW text as each piece is emitted (never linkify already-escaped text — it double-escapes and swallows entities), matches http/https only, attribute-escapes the href, and leaves a deceptive authority (`user@host`, backslash) as inert text #security
- [decision] Dark-mode normalization is CONSERVATIVE: `MailTheme.Web.light/dark` tokens mirrored into CSS custom properties style only the document's own unstyled regions, links, quote bars and disclosure — a sender's colours are never inverted #design

## Relations
- relates_to [[Herald Error Handling and Security Rules]]
- relates_to [[Herald Design System and Accessibility]]
- relates_to [[HQBase Mail API v1 Contract]]



## Update (2026-09-27 — redesign R6, task t-91abc484, commit 02948d3)

- [decision] The reading-pane HEADER (subject, "Message N of M", sender block with the To/From domain-badged address chip, toolbar reorder) is rebuilt to the handoff — full layout in "Herald Design System and Accessibility"'s R6 update. `MailViewModel.composeBody`'s fragment assembly (html + collapsed `<details>` quotedHtml + afterQuotedHtml) is UNCHANGED — still the single assembly point this note describes #reading-pane
- [fact] The shared web-document CSS (`MailViewModel+HTMLAssembly.swift`'s `styleSheet`, the one emitter every WKWebView in the app uses) gained one line: `body { … max-width: 600px; }` — the handoff's reading-pane body width cap. Shared with `SignaturePreviewView`, whose own preview box is already narrower than 600px, so this is a no-op there #webkit
