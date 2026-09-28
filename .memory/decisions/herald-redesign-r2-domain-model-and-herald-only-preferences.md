---
title: Herald Redesign R2: Domain Model and Herald-Only Preferences
type: note
permalink: hqbase-mac/decisions/herald-redesign-r2-domain-model-and-herald-only-preferences
source_paths: [Herald/Design/MailboxColorAssignment.swift, Herald/App/SignatureSettingsModel.swift]
source_paths_inferred: false
source_sha: a29354f5c5323ef8bca650bbc105d13fb4bf8d17
created: 2026-09-27
updated: 2026-09-28
---

## Observations
- [decision] `MailDomain` (`HeraldKit/Sources/HeraldKit/Model/MailDomain.swift`) is a total, pure derivation from `[Mailbox]`, grouped by the primary address's `mailDomainID` — the API pins `Mailbox.addresses` to exactly one item, so this is normally a straight group-by. Two fallbacks guard a cache row that predates that contract rather than a real server response: no `mailDomainID` but a parseable address → grouped by the domain NAME (`"domain-name:<name>"`, so it still merges with peers on that name, never claiming a server id); nothing parseable at all → `MailDomain.fallbackID`/`fallbackName` ("unassigned" / "(no domain)"). A mailbox is never dropped from every domain-scoped view. Order is deterministic (domains alphabetical by name, mailboxes by local part), not dependent on input order. Replaces the identical, address-only `SignatureSettingsModel.domainName(of:)` — that call site now reuses `MailDomain.domainName(of:)` #domains
- [decision] `DomainMonogram` (`Herald/Design/DomainMonogram.swift`): 2 letters from the domain's first DNS label, uppercased; promoted to 3 for EVERY domain in a same-account clash group (not just the first two); a per-domain override (2–3 letters, validated) always wins and is never itself promoted/demoted. If a promoted group still collides at 3 letters (e.g. "notion.io"/"notable.io" both → NOT), both keep the shared text — the design's uniqueness guarantee stops at 3 letters, and the badge is always paired with the tint wash and the full domain name, never the sole distinguisher #domains #monogram
- [decision] `DomainPreferences` (`Herald/Support/DomainPreferences.swift`): Herald-only per-(account, domain) prefs in an injected `UserDefaults` (never `.standard` directly — same pattern as `NotificationSettings`), keys `domain.<accountID>.<domainID>.{monogram,includeInAll,countInBadge,notify,hidden,hiddenAt}`. Defaults: `includeInAll`/`countInBadge` ON, `hidden` OFF, `notify` `nil` (follow `NotificationSettings.newMailEnabled`). Re-hiding a previously-restored domain stamps a FRESH `hiddenAt`, not the original. `hiddenDomainIDs(accountID:in:)` scans the defaults key space itself (no separate index) for the Hidden Domains list; `purgeAll(accountID:from:)` exists for a later phase to call from sign-out — R2 does NOT wire it in #domains #preferences
- [decision] Account tint: `AccountTintAssignment` (`Herald/Design/AccountTintAssignment.swift`) reuses `MailboxColorAssignment`'s FNV-1a hash verbatim (now `internal`, not `private`, for exactly this reuse) keyed on the account id, over the fixed ordered token list `["clay","ochre","moss","sage","slate","dusk","plum","rose"]` — a contract with the parallel R1 phase, which owns the actual `MailTheme` colours for those names; this type never references them. Override at `account.<accountID>.tint`; unknown/stale override falls back to the hash. Account id is NOT lowercased (unlike the mailbox-address hash) — it's already `Account.normalize(origin).absoluteString`, a single canonical casing #tint
- [decision] `ListDensity` (`Herald/Support/ListDensity.swift`): `comfortable | compact` at `list.density`, applies to every account, defaults `comfortable`; an unrecognised stored value also falls back to `comfortable` #density
- [fact] Tests: `HeraldKit/Tests/HeraldKitTests/MailDomainTests.swift` (9) + `HeraldTests/{DomainMonogramTests,DomainPreferencesTests,AccountTintAssignmentTests,ListDensityTests}.swift` (40) — clash promotion (incl. groups of 3+, still-clashing at 3 letters), override precedence/fallback for a stale value, exact key-name assertions, `hiddenDomainIDs` with a dotted fallback domain id, totality of the `MailDomain` derivation (empty/no addresses array). Full suites green at landing: HeraldTests 441/441 (was 401), HeraldKit 458/458 (was 449) #testing

## Relations
- relates_to [[Herald Architecture]]
- relates_to [[Herald Design System and Accessibility]]
- relates_to [[Herald Signature Handling]]
- relates_to [[HQBase Mail API v1 Contract]]


## Update (2026-09-27 — orchestrator review: key-collision fix)
- [gotcha] `DomainPreferences` keys originally interpolated `accountID`/`domainID` raw into `domain.<a>.<b>.<field>`. `accountID` is `Account.normalize(origin).absoluteString` (e.g. `https://mail.example`), which contains dots, and same-host-prefix origins are realistic (`https://mail.example` vs `https://mail.example.org`). A naive `hasPrefix("domain.\(accountID).")` in `hiddenDomainIDs`/`purgeAll` then also matched the LONGER account's keys (`domain.https://mail.example.org.<dom>.hidden` starts with `domain.https://mail.example.`), leaking a mangled hidden-domain id across accounts and letting `purgeAll` delete another account's keys #bug
- [decision] Fixed by percent-escaping each key component before it goes into the key (`.` → `%2E`, `%` → `%25`; `escapeKeyComponent`/`unescapeKeyComponent`, private to `DomainPreferences`) — an escaped component can never itself contain an unescaped `.`, so `domain.<escaped accountID>.` is safe as an exact prefix regardless of what either account id contains. Applies to BOTH `accountID` and `domainID` (this module's own `MailDomain` fallback ids already contain dots, e.g. `"domain-name:acme.co"`). `AccountTintAssignment`'s `account.<accountID>.tint` key needed no equivalent fix — it is only ever read/written by its own exact key, never scanned or prefix-matched. Tests: `DomainPreferencesTests.hiddenDomainIDsDoesNotLeakAcrossPrefixRelatedAccounts`/`purgeAllDoesNotTouchPrefixRelatedAccount` (prefix-related account ids `https://mail.x` vs `https://mail.x.y`), `keysEscapeDotsAndPercent` (pins the exact escaped form) #bug #fix



## Update (2026-09-27 — R3b)
- [fact] CORRECTION: `MailboxColorAssignment` no longer exists; its hash now lives at `AccountTintAssignment.stableHash` (unchanged, incl. the non-standard multiplier — see "Herald Design System and Accessibility" R3b). `DomainPreferences.purgeAll` IS now called from sign-out via `PreferenceHygiene.purgeAccount` (Herald/Support/PreferenceHygiene.swift) #preferences



## Update (2026-09-27 — server-disabled mailboxes and domains; commits 1bc5c1c, 71d77e2)
- [decision] A mailbox counts as enabled when `Mailbox.isEnabled` is true, i.e. `isActive && (addresses.first?.domainEnabled ?? true)`. The filter lives in ONE place: `MailViewModel.reloadMailboxes()` sets `mailboxes` to the enabled ones and keeps the rest in a private `disabledMailboxes`. Every domain-shaped surface (sidebar, counts, Dock badge, notifications, All domains, Settings, compose, reading-pane badge) reads from there. It is NOT in `MailStore.mailboxes` (sync uses that to decide purges) and NOT in `MailDomain.domains(from:)` #disabled-chokepoint
- [fact] HQBase has two switches. `Mailbox.isActive` is in v1. The domain "Active" toggle (`mail_domains.is_enabled`; disconnecting a domain also sets it to 0) is NOT in v1 until the upstream `MailboxAddress.domainEnabled` change lands (draft: documents/plans/hqbase-upstream-domain-enabled-2026-09-27.md). Herald's vendored spec has `domainEnabled` as OPTIONAL; a missing value means enabled (old servers). `scripts/vendor-openapi.py` has a KEEP_OPTIONAL list so a re-vendor of the upstream spec (where it is required) never makes the field mandatory #domain-enabled
- [decision] Rules that follow from this:
  - When any mailbox is disabled, the "every mailbox" shortcut (nil) in `mailboxIDs(for: .allDomains)` / `badgeMailboxIDs()` is not used. Side effect: unassigned/catch-all rows drop out of All domains, the same as when a domain is hidden.
  - A change in the disabled set reloads conversations and drafts.
  - A change set that touches mailbox rows reloads mailboxes BEFORE new-mail notifications go out.
  - Monograms are assigned over enabled AND disabled domains (`monogramDomains` / `monogramMailboxes`), so turning one off never changes another domain's letters.
  - Reply, reply-all and forward from a disabled mailbox are refused with a plain message; only a brand-new message falls back to an enabled mailbox.
  - Stored drafts keep their own mailbox and From.
  - `ownAddresses` still includes disabled mailboxes.
  - Settings hides disabled mailboxes, but their Herald preferences are kept, so everything returns when re-enabled.
  #disabled-rules
- [fact] Sync still downloads and caches mail for disabled mailboxes; only what Herald shows is filtered #disabled-sync



## Update (2026-09-28 — R9)
- [fact] CORRECTION: the key set grew by one. `DomainPreferences` now also has `domain.<accountID>.<domainID>.hiddenName` — the domain's name captured at hide time, written by `setHidden`'s new `name:` param and cleared alongside `hidden`/`hiddenAt` on restore. See "Herald Settings Window Architecture" R9 update for the Remove-domain page and `HiddenDomainItem` this feeds #domains #preferences
