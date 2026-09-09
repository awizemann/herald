# Full-surface audit 2026-09-04 (post 1.3.4-adoption run, branch feat/upstream-134-adoption)

Four specialist read-only audits over the entire touched surface (old code included): security, performance, data integrity, accessibility. Full agent reports summarized; findings triaged into fix tasks A1–A5.

## Security (swift-security-specialist) — NO high findings
Sound: full OAuth stack (PKCE, discovery https+same-host pinning, token provider rotation arbitration, Keychain usage), attachment sanitization/quarantine, HTML containment (CSP, rule list, navigation policy, escaping, deceptive-authority linkifier), analytics privacy design ("exemplary").
Actionable (low): (1) URLSessionMailEventChannel maps http→ws and would send a bearer over plaintext if ever handed an http origin — refuse at the library boundary; (2) empty token silently downgrades socket to cookie-session auth — throw instead, tests use the existing seam; (3) OAuthHTTP buffers whole responses before the size cap — stream. Informational: mimeType shape guard at inline-image assembly; filename clamp is chars not bytes (reliability nit). → task A4.

## Data integrity (swiftdata-specialist)
- HIGH: Codable-blob columns (CachedMessageBody.attachments, CachedDraft.signature/attachments, CachedMailbox.addresses) — adding a required field to the DTOs breaks fetch-time decode but never triggers the container's delete-and-rebuild valve (that only guards open()); cache is permanently broken. Fix: decode-error-on-fetch → store-nuke trigger + convention that new DTO fields are optional/defaulted. → A1
- HIGH: deleteMissingMessages orphans body sidecars + label assignments + pending fences (deleteMessage/purgeMailbox cascade; this path doesn't). → A1
- MEDIUM: label optimistic writes have no pending fence — all interleavings verified CONVERGENT; residual is the documented ≤120s window. Accepted.
- MEDIUM: sweep can insert assignments for messages the cache never held (label count vs listing disagree) — inherent to v1 API; accepted, comment it. → A1 (comment only)
- LOW: revertLocalAction can delete a server-claimed scope row (self-healing, transient); storeBody can't clear attachment metadata (deliberate). Accepted.
- Sound: purge completeness, checkpoint/cursor integrity incl. re-bootstrap cooldown, journal ordering, pending-mutation fences, draft fence, sweep write-safety.

## Performance (performance-specialist) — at 10k msgs / 20 labels
- P1: label sweep = 20+ page-walks per 120s forever regardless of activity — dominant idle cost. Fix: visibility-gated cadence (aggressive only when label UI on screen; 10–15 min otherwise), skip replaceAssignments when row-set unchanged; upstream ask candidates already filed in the PR-queue note. → A3
- P1: conversations(withLabel:) materializes every CachedConversation per reload (fetchLimit=nil). Fix: propertiesToFetch/fetchBatchSize or chunked OR predicate. → A3
- P2: labelIDsByThread whole-table fetch (propertiesToFetch or incremental maintenance); sidebar badge O(threads×labels) in body per render (precompute counts, use Set); setLabel does redundant sequential reloads. → A3
- P2 (bigger, deferred): inline images as base64 data URLs → ~4-5x memory (fix = WKURLSchemeHandler herald-cid://, plus bounded task-group concurrency); attachment downloads buffer whole payload (fix = URLSession.download to scratchpad, sniff from prefix). → A5 (follow-up task)
- P3: escaping allocator churn (fine); informational: no signposts/MetricKit.
- Sound: MailEventSocket ("exemplary"), refilter, list rendering, HTML assembly threading, store diffing.

## Accessibility (mobile-a11y-specialist)
- H1: signature menu rows convey selection visually only (checkmark image, empty-string SF symbol = undefined behavior) — use Toggle rows like LabelMenu. H2: disabled saved-copy row gives no reason. H3: label/mailbox chip NAME drawn in the tint fails AA for yellow/orange/teal in light mode — draw name in primary, tint stays on fill. H4: ReauthBanner "Signing you back in…" transition never announced; focus dropped when button vanishes — post AccessibilityNotification.Announcement. → A2
- M1: BannerView icon not accessibilityHidden. M2: banners (remote-image consent, inline-image failure, search status) appear silently — announce. M4 nits: details summary cursor:pointer; glyph state cue subtle (VO covers via native expanded/collapsed). M5: web palette AA-passes (contrast math verified) but ignores Increase Contrast — add prefers-contrast: more block. → A2
- M3: no menu-bar Labels command (house rule: Commands for every mail action) + no label rotor entries. → A2 (menu command; rotor noted)
- L1-L4: double-read signature value, unlabeled busy spinner, fixed slots vs large text (@ScaledMetric polish). → A2 lows where cheap, else noted.
- Sound: rows/rotor/TriageButtons/sidebar/unread/Reduce Motion/settings toggle/compose/web document basics.

## Fix tasks
- A1 t-? data integrity: decode-nuke trigger, deleteMissingMessages cascade, accepted-behavior comments.
- A2 t-? accessibility: H1–H4 + M1/M2/M4/M5 + menu-bar Labels command + cheap lows.
- A3 t-? performance: sweep cadence gating, label store fetch tuning, badge precompute, setLabel reload dedup.
- A4 t-? security hardening: ws:// refusal, empty-token throw, streamed OAuth cap, mimeType shape guard, byte-clamp filename.
- A5 t-? (follow-up, larger): WKURLSchemeHandler inline images + streamed attachment downloads.
