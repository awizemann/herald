# Herald feature investigation — 2026-08-18

Scope: attachments in compose, drafts folder, search, multiple accounts UI, notifications.
Caveat: `~/Developer/hqbase` checkout is behind upstream main (lacks #35 pagination and #37 changes feed, both merged upstream).

## 1. Attachments in compose — mostly built
- Have: `OutboxService.attach` (10 MiB client cap), compose chips, save-on-receive, forward via `/send`.
- API: `POST /drafts/{id}/attachments` (25 MiB/file, 25 MiB/draft, ≤20); `attachmentIds` on send/reply must be draft attachments.
- Client: raise cap to 25 MiB + per-draft total + count guard (t-8a1c0014); drag-drop/paste; in-flight UI; QuickLook + drag-out.
- Upstream: (a) spec declares no per-part Content-Type on `file` → uploads stored as octet-stream (`HQBaseAPIClient.swift:301` discards MIME); (b) expose `forwardMessage(includeOriginalAttachments)` on /api/v1; (c) advertise limits.

## 2. Drafts folder — client-heavy
- Have: drafts CRUD in `MailAPIClient`, autosave w/ 409 retry, `listDrafts()` unused; sidebar hides Drafts.
- API: `GET /drafts` (no pagination/updatedSince); drafts are separate tables, not messages; `folder=drafts` on /messages is dead; not in /changes journal.
- Client: special sidebar item, draft cache in MailStore polled via `listDrafts()` full-list diff, open ComposeWindow from `Draft.editableContent`, delete.
- Upstream: drafts in changes journal or `updatedSince`; document/remove dead `drafts` message-folder value.

## 3. Search — client can ship now
- Have: local substring filter over subject+from+snippet; `search:` param plumbed but unused.
- API: `search=` = LIKE %term% over subject/from/to_json/snippet/text_body, full scan, per-folder only, wildcards unescaped; pageable via #35.
- Client: two-tier (local widened index → server `GET /conversations?search=` for selected folder), client-side highlight.
- Upstream: FTS5 + triggers (design Issue first); escape LIKE wildcards (tiny PR); cross-folder search; attachment-name match.

## 4. Multiple accounts UI — client only
- Model/store/sync already per-account (accountID on every model, SyncEngine per account, per-account tokens/DCR).
- Choke point: `AppEnvironment.swift:98` `accounts.first` + single account/syncEngine/mail/outbox fields; second account tears down first.
- Client: dictionaries keyed by Account.ID + selectedAccountID; sidebar switcher; scope signOut/reauth; compose VMs keyed by account; aggregate unread. Risks: N sync loops on one container, N refresh timers.

## 5. Notifications — client only for local
- Have: nothing; but `ChangeSet.inserted` distinguishes new vs updated at `MailViewModel.apply`.
- Server: only browser Web Push (VAPID) on inbound ingress; no APNs/SSE.
- Client: local UNUserNotificationCenter from inserted inbound/unread, gated on bootstrappedAt; Dock badge; click → select. Latency = poll.
- Upstream: SSE/long-poll `GET /api/v1/changes/stream` over the journal.

## Recommended order
5 → 4 → 1 polish → 2 → 3. Open small Issues now (MIME part type, LIKE escaping); design Issues for FTS, changes/stream, drafts journal.
