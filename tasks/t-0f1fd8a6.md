---
id: t-0f1fd8a6
title: Redesign R2: Domain model & Herald-only prefs
status: done
added: 2026-09-27
priority: high
---

## Description

Phase R2. Pure, additive, unit-tested: MailDomain derivation from [Mailbox], DomainMonogram (2 letters, 3 on clash within one account, override wins), DomainPreferences (UserDefaults domain.<accountID>.<domainID>.{monogram,includeInAll,countInBadge,notify,hidden,hiddenAt}), AccountTint assignment (FNV-1a keyed on account id + override account.<accountID>.tint), ListDensity pref list.density. No UI. Wave 1, no deps.

## Plan



## Artifacts



