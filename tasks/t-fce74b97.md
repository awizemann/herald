---
id: t-fce74b97
title: WF4: Classification engine on new mail
status: done
added: 2026-09-29
priority: high
---

## Description

Hook beside MailViewModel.notifyNewMail (per sync ChangeSet). Eligibility (pure, tested): inbound, inbox, mailbox belongs to a domain with classification ON, receivedAt >= enabledAt, thread has NO label at all in cache (classify each thread once — never re-tag), no earlier inbound message in thread, not already attempted (bounded memo). Serial actor queue, cap ~60 calls/hour, errors logged not surfaced per message (surface gateway-level failures once, e.g. auth). Fetch plain text body via existing message detail path. Apply chosen label to the THREAD via MailActionService.setLabel(onConversation) — re-check "thread still unlabeled" right before applying. Tests with fakes for client + store: each eligibility rule, re-tag prevention, none → no write, cap, error paths.

## Plan



## Artifacts

Commit 32feecb (feature/workflows-classification).
- Engine: HeraldKit/Sources/HeraldKit/AI/ClassificationEngine.swift (pure eligibility statics + actor, serial drain, 60/h cap, pause-once, activity ring for WF5).
- App: Herald/Support/ClassificationSupport.swift (ClassificationContextBuilder, WorkflowAttemptLog); hook MailViewModel.classifyNewMail beside notifyNewMail; wiring in AppEnvironment.install; AccountGraph.stop awaits engine.stop; Workflows page shows pause + Resume.
- Store: MailStore.threadHasLabels.
- Tests: HeraldKit ClassificationEngineTests (35 incl. eligibility rules, race, none, cap, serial, pause-once, per-message errors, memo, persistence, stop) + HeraldTests ClassificationContextTests (6). Full suites green: app 718, HeraldKit 527.
- Open: cache-trust limits (uncached older messages / label-sweep lag), cap/paused jobs not retried, token replacement needs manual Resume.

