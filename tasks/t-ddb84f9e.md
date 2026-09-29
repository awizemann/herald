---
id: t-ddb84f9e
title: 1.0: hardening pass (UI suite 5x, upgrade from 0.5.1, 1.3.4 compat)
status: done
added: 2026-09-28
---

## Description

Phase E (Opus), after A+B merge. Full unit + UI suites; UI suite 5x consecutively (closes t-23673507); cache rebuild on upgrade from 0.5.1 store; old mailbox-colour prefs ignored; minimum server 1.3.4 still works; adversarial audit of redesign + compose.

## Plan



## Artifacts

2026-09-28 hardening pass (Opus agent):
- Unit: HeraldKit 479/479 (swift test, 69 s); Herald 684/684 at 7cfad7b, 685/685 after fix (xcodebuild, dedicated derivedDataPath, ~2 min).
- UI: 13/13 once at 64a71c2 (345 s); 12/13 at 7cfad7b (1 "Timed out while synthesizing event", spindump shows Herald idle = contention). 5x consecutive NOT achieved: testmanagerd contention from concurrent ShabuBox test runs, then screen locked. t-23673507 left open.
- Upgrade 0.5.1 -> HEAD: @Model schema unchanged since v0.5.1; store written by v0.5.1 MailStore opens in place with HEAD (same inode, 150 rows, blobs decode, domainEnabled defaults true). Legacy mailboxColor.* prefs purged once by PreferenceHygiene (tested).
- Server 1.3.4: code review of v0.5.1..HEAD — no new endpoints; only new field domainEnabled is optional (?? true); attachment content-type widened to */*. Local HQBase instance not running and app is https-only, so not exercised live.
- Fix: 64a71c2 fix(compose): ignore an autosave answer that lands after the send (+ HeraldTests/ComposeSendSaveRaceTests).
- Open findings: local-search cache paging runaway (MailViewModel.swift loadMoreConversations ~2074), server-branch chained backfill with no new rows, LoadMoreRow silent to VoiceOver.

