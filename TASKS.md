# Tasks

> Repo-resident task board managed by Memophant and Claude sessions. Move items between
> sections as work progresses; checklist state mirrors the section.

## Ideas

- [ ] Multi-account UI (model already supports it) (id: t-8a1c0016) (added: 2026-08-15) (priority: medium)
- [ ] WebKit-level navigation policy test + ⌘F search focus (id: t-8a1c0015) (added: 2026-08-15) (priority: low)
- [ ] PrivacyInfo.xcprivacy + App Store readiness pass (id: t-8a1c0013) (added: 2026-08-15) (priority: low)
- [ ] Upstream: PR pagination + updatedSince for GET /api/v1/messages (id: t-8a1c0007) (added: 2026-08-15) (priority: low)

## Todo

- [ ] UI: re-auth banner should stack above the account header, not replace it (id: t-8a1c0052) (added: 2026-08-18) (priority: low)
- [ ] Verify journal-mode sync live once an HQBase release includes #35/#37; retire the 100-cap guard note (id: t-8a1c0051) (added: 2026-08-18) (priority: high)
- [ ] Wire "Put back" from Trash once upstream ships a restore action (HQBase/hqbase#42; Herald #7) (id: t-8a1c0050) (added: 2026-08-18) (priority: medium)
- [ ] Reading pane polish: collapse quoted history, system font for text/plain bodies (id: t-8a1c0017) (added: 2026-08-15) (priority: medium)
- [ ] Keychain I/O off the main actor at boot (id: t-8a1c0012) (added: 2026-08-15) (priority: low)
- [ ] Optimistic action vs concurrent sync pass fence (id: t-8a1c0011) (added: 2026-08-15) (priority: medium)
- [ ] Follow-ups from 2026-08-18 feature audit (compose test handshake, pendingRoute clearing, stale search field, quotedBody dead code) (id: t-19d0d9ef) (added: 2026-08-18) (priority: low)

## Doing

- [ ] Dogfood against a real HQBase 1.1.0 server: add account, sync, read, reply (id: t-8a1c0010) (added: 2026-08-15) (priority: high)

## Done

- [x] Analytics P5: keyed E2E run, fresh-eyes audit, commit, record decisions (id: t-197c4c10) (added: 2026-08-18) (priority: high)
- [x] Upstream PR #34 (`hqbase domain`): address bermanto's changes-requested review (id: t-7d2e71be) (added: 2026-08-18) (priority: high)
- [x] Analytics P4: Settings Privacy tab opt-out + README/release-notes disclosure (id: t-1a8767ad) (added: 2026-08-18) (priority: high)
- [x] Analytics P3: instrument AppEnvironment/MailViewModel/ComposeViewModel + lifecycle (id: t-a73fa929) (added: 2026-08-18) (priority: high)
- [x] Analytics P1: swift-stats package + Analytics module + wire tests (id: t-e425c325) (added: 2026-08-18) (priority: high)
- [x] Analytics P2: write-key plumbing (Info.plist, release.sh, verify 3 cases) (id: t-dcb470be) (added: 2026-08-18) (priority: high)
- [x] Fix release.sh cosmetic "(dry run)" label that shows on every run (id: t-043ea358) (added: 2026-08-18) (priority: low)
- [x] P3 Upstream Issue drafts: MIME part type, LIKE escaping, FTS, changes/stream, drafts journal (id: t-90f087d0) (added: 2026-08-18)
- [x] P5 Drafts folder: sidebar item, draft cache polled via listDrafts, resume/delete (id: t-844a7a0f) (added: 2026-08-18)
- [x] P6 Search: widen local index + escalate to server search for the selected folder (id: t-b0632395) (added: 2026-08-18)
- [x] P4 Notifications: local new-mail notifications + Dock badge from ChangeSet.inserted (id: t-051b3799) (added: 2026-08-18) (priority: high)
- [x] Enforce per-draft 25 MiB attachment total client-side (id: t-8a1c0014) (added: 2026-08-15) (priority: low)
- [x] P2 Attachments polish: 25 MiB caps, drag/paste, in-flight UI, QuickLook (id: t-0f5393b9) (added: 2026-08-18)
- [x] P1 Multi-account: per-account graphs in AppEnvironment + sidebar account switcher (id: t-a78d4e01) (added: 2026-08-18) (priority: high)
- [x] Split MailStore.swift (1254) and MailViewModel.swift (1183) under the 1000-line limit (id: t-9f94365e) (added: 2026-08-18)
- [x] Replace KeychainAccountStore NSLock with os_unfair_lock (not actor — sync nonisolated protocol) (id: t-e2af8452) (added: 2026-08-18)
- [x] Add MailTheme token scales (spacing/radius/typography/animation) and migrate literals (id: t-2144407d) (added: 2026-08-18) (priority: high)
- [x] Low-risk audit hygiene: comment try? decodes, fix TOCTOU, log revert failures, drop constant force-unwrap (id: t-47993e16) (added: 2026-08-18) (priority: low)
- [x] Herald: checkpoint + /changes sync; drop 100-cap guard (after PR-B ships) (id: t-8a1c0042) (added: 2026-08-17) (priority: high)
- [x] Upstream PR-B (built by bermanto as HQBase/hqbase#37 — moot): GET /api/v1/changes journal endpoint (triggers, sequence cursor, envelope) + spec PR (id: t-8a1c0041) (added: 2026-08-17) (priority: high)
- [x] Upstream PR-A: GET /api/v1/messages pagination (limit, versioned cursor, Link header) + hqbase-site spec PR (id: t-8a1c0040) (added: 2026-08-17) (priority: high)
- [x] Verify Sparkle self-update: cut 0.1.1 and confirm running 0.1.0 offers + installs it (id: t-8a1c0028) (added: 2026-08-16) (priority: high)
- [x] UI: humanized row date in fixed trailing slot with full-date tooltip + a11y value (id: t-8a1c0031) (added: 2026-08-16) (priority: high)
- [x] UI: mailbox chip primary in rows, per-mailbox color (deterministic default, Settings override), sender secondary (id: t-8a1c0030) (added: 2026-08-16) (priority: high)
- [x] Cut v0.1.0: keys + notary profile (owner), release.sh, enable gh-pages — SHIPPED 2026-08-16 (id: t-8a1c0027) (added: 2026-08-15) (priority: high)
- [x] Sparkle 2 auto-update: SPM dep, sandbox XPC entitlements, new EdDSA key, Check for Updates menu, GitHub Pages appcast, release.sh port from ShabuBox (id: t-8a1c0026) (added: 2026-08-15) (priority: high)
- [x] Lower deployment target to macOS 15 (Package.swift, project.yml, CI runner) (id: t-8a1c0025) (added: 2026-08-15) (priority: high)
- [x] UI: show mailbox name on rows in All Mailboxes view (id: t-8a1c0024) (added: 2026-08-15) (priority: high)
- [x] UI: Starred folder in sidebar (id: t-8a1c0023) (added: 2026-08-15) (priority: high)
- [x] UI: thread drill-in replaces conversation list with back header (id: t-8a1c0022) (added: 2026-08-15) (priority: high)
- [x] UI: mailbox picker at top of sidebar replacing per-mailbox sections (id: t-8a1c0021) (added: 2026-08-15) (priority: high)
- [x] UI: fixed-height sync status (no layout jump) (id: t-8a1c0020) (added: 2026-08-15) (priority: high)
- [x] P0.6 Audit + polish: specialist fan-out, fixes, dogfood build (id: t-8a1c0006) (added: 2026-08-15) (priority: medium)
- [x] P0.5 Compose: reply / new message window, OutboxService (id: t-8a1c0005) (added: 2026-08-15) (priority: medium)
- [x] P0.4 UI: MailViewModel, three-pane split view, conversation list, reading pane, actions + Commands (id: t-8a1c0004) (added: 2026-08-15) (priority: high)
- [x] P0.3 Sync + store: SwiftData cache, MailStore @ModelActor, SyncEngine actor, diff tests (id: t-8a1c0003) (added: 2026-08-15) (priority: high)
- [x] P0.2 Auth: OAuth discovery, dynamic registration, PKCE via ASWebAuthenticationSession, refresh, AccountStore (id: t-8a1c0002) (added: 2026-08-15) (priority: high)
- [x] P0.1 Scaffold: project.yml, HeraldKit package, generated Mail API client, DTOs, KeychainStore (id: t-8a1c0001) (added: 2026-08-15) (priority: high)

## Archived

