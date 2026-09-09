# Investigation 2026-09-04: Upstream 1.3.4 delta + four client defect areas

## Upstream state (HQBase 1.1.2 → 1.3.4, released 2026-09-01)
Every issue Herald filed is CLOSED/COMPLETED. API additions vs vendored spec:
- `POST /api/v1/forward` (+`ForwardInput`) — closes #46
- Message action enum now includes `unarchive` and `restore` — closes #42 (unblocks Herald "Put back", t-8a1c0050)
- `GET /api/v1/drafts/changes` (draft change journal) + `GET /drafts` now paged (`limit`/`cursor`/`search`) — closes #47
- `GET /api/v1/events` — wake-only **WebSocket** (`{"type":"changed","topic":"messages|drafts|mailboxes|labels"}`, no payloads, 10-min lease, reconnect with current credentials) — closes #48
- Labels: `GET /labels`, PUT/DELETE label assignment on messages/conversations/drafts, `labelId(s)` filters
- Signatures: `GET /api/v1/signatures` (+ Signature schemas)
- `GET /drafts/{draftId}/attachments/{id}/inline`
- `refreshTokenReuseInterval: 30` in worker/auth/auth.ts:132 — closes #41 (concurrent-client family invalidation)
- #45 (multipart Content-Type) closed — regen and honor per-part type
- Session binding UNCHANGED: oauth-principal.ts still rejects tokens when the bound web session (7d sliding) expires → periodic reauth remains; client-side auto-reauth is the fix.

## Findings by area (agent reports, file:line verified)

### A. Reauth
- `needsReauth` set at Herald/App/MailViewModel.swift:1092-1095; banner → `AppEnvironment.reauthenticate` (AppEnvironment.swift:573) which re-runs the full add-account flow.
- No silent path exists; `ASWebAuthenticationSession` always shows UI, but with `prefersEphemeralWebBrowserSession=false` (AuthorizationPresenter.swift:23-33) the live HQBase cookie completes consent instantly — that is the "minimal" reauth observed.
- Fully headless reauth impossible (sandbox cannot reach the browser cookie jar). Achievable: auto-invoke the existing flow, rate-limited, at MailViewModel.swift:1092 (before showing the banner) or via an escalation hook at AccountTokenProvider.swift:131-134; fall back to banner on cancel/failure. `performSignIn` needs a quieter variant (sets isSigningIn/sheet state, AppEnvironment.swift:552-557).

### B. Attachments (ranked root causes)
1. `HQBaseAPIClient.attachmentData` hardcodes `application/octet-stream` (HQBaseAPIClient.swift:160); `AttachmentFile.filename(for:)` therefore appends `.dat` for extension-less names → QuickLook blank. Server `attachment.contentType` is effectively dead code (AttachmentFile.swift:88).
2. Attachments not persisted in SwiftData (only `hasAttachments`); offline/flaky `GET /messages/{id}` → whole AttachmentBar vanishes while body renders from cache = "sometimes not loading".
3. Cached-body fallback skips `substituteInlineImages` → broken `cid:` images offline (MailViewModel.swift:1487-1492).
4. Inline failures silent; MIMESniffer only knows a few image magics → legit inline images dropped by renderability gate.
5. Preview staleness guard on stale captured list (ReadingPaneView.swift:200); `previewURL` never cleared; 16-entry LRU can delete files under live QuickLook/drag (AttachmentFile.swift:70-73).
6. Save path double-downloads, bypasses cache; whole-payload memory buffering (64 MiB cap, + base64 copy inline).

### C. Formatting/threads
- Highest leverage: server already returns `MessageHTML.quotedHTML` split out for collapsing (Message.swift:146) — Herald discards it (MailViewModel.swift:1466). Add "Show quoted history" collapse.
- No dark-mode normalization beyond `color-scheme: light dark` (MailViewModel+HTMLAssembly.swift:86) → light emails glare in dark app.
- Blockquote styling one-line, no nesting hierarchy (+HTMLAssembly.swift:91). Plain text: no linkification, no `>`-quote styling, monospace `<pre>` only.
- Threads: single-message reading pane by design; no stacked conversation. Stacking = bigger project (needs JS height reporting; JS currently disabled). Existing task t-8a1c0017 covers pane polish.
- Misc: naive `cid:` string replace; no zoom/text size; wide tables overflow.

### D. Reply quoting
- `ComposePrefill.quotedBody/quoteHeader` exist but are dead code; reply body deliberately empty (server appends quote on POST /reply) — sent thread DOES get the quote after sync; compose shows nothing. Fix: read-only collapsed quoted preview under the TextEditor (ComposeWindow.swift:78-84), plumbed via ComposeContext.makeDraft; must never concatenate into bodyText (would double the quote on send).
- BUG: forward sends via POST /send; `SendInput` has no forward link — only `draftId` carries `forwardOfMessageId`. Forward before autosave persists a server draft ⇒ forwarded content lost. Adopt new `POST /forward` to fix properly.

## Plan (phased; each phase = plan→execute→test→audit→commit)
- **P1 — API refresh + quick server-fix adoption**: re-vendor spec @1.3.4, regenerate client; adopt `restore`/`unarchive` (wire "Put back", t-8a1c0050); adopt `POST /forward` (fixes forward-loss bug); send multipart Content-Type on draft attachment upload. Precondition check: Alan's instance version must be ≥ the feature's release (verify live; 1.3.4 is current).
- **P2 — Auto minimal reauth**: quiet reauthenticate variant; auto-trigger on needsReauth (rate-limited, once per expiry, only when app frontmost); banner remains fallback. Note reuse-interval server fix removes the two-process logout class once instance ≥1.2.x.
- **P3 — Attachments hardening**: use server contentType + extended MIMESniffer (PDF/ZIP/OOXML) for downloaded files; persist attachment metadata in the message cache (offline bar); substitute inline images in cached-body fallback; fix preview staleness/eviction (refcount or clear-on-close); reuse cache on save.
- **P4 — Reading formatting**: quotedHTML collapse toggle; dark-mode body normalization; blockquote hierarchy CSS; plain-text linkification + quote tinting; table overflow containment. (Stacked thread view deferred — separate design task.)
- **P5 — Reply quote preview in compose**: display-only collapsed quote fed by ComposePrefill.quotedBody; reply-all/forward too.
- **P6 — Events WebSocket + delta sync verification**: adopt `GET /api/v1/events` wake socket to replace/thin the poll loop; complete t-8a1c0051 (verify checkpoint+/changes live, retire 100-cap guard) and adopt drafts/changes journal for the drafts cache.
- Later/roadmap: labels UI, signatures support (new upstream features).
