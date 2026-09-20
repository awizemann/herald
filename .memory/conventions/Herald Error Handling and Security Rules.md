---
title: Herald Error Handling and Security Rules
type: note
permalink: hqbase-mac/conventions/herald-error-handling-and-security-rules
tags: [errors, security]
source_paths: [HeraldKit/Sources/HeraldKit/Auth/AccountTokenProvider.swift, HeraldKit/Sources/HeraldKit/Auth/OAuthSession.swift, HeraldKit/Sources/HeraldKit/Auth/AccountStore.swift, HeraldKit/Sources/HeraldKit/Auth/OAuthError.swift]
source_paths_inferred: false
source_sha: 66af754e21d29354c9691fd6fac75a8c20fad963
created: 2026-08-16
updated: 2026-09-19
reviewed: 2026-09-19
reviewed_by: claude-opus-5[1m]
---

## Observations
- [rule] Every catch logs (logger.warning for expected: 401/refresh/offline; logger.error for unexpected: decode failure, logic), rethrows, or returns .failure — never swallow; bare try? only for ignorable ops #errors
- [rule] Tokens (access/refresh) and OAuth client registration live in the Keychain via a small `KeychainStore` (kSecClassGenericPassword, service com.wizemann.herald, account = origin); never in UserDefaults, logs, or memory notes #keychain
- [rule] Redact addresses/subjects/bodies in production logs (log ids and counts) #privacy
- [rule] Message HTML is untrusted: rendered only in a WKWebView with JavaScript disabled, remote loads blocked by WKContentRuleList until the user trusts the sender (mirrors the server's remote-media trust), links opened via NSWorkspace not in-web-view navigation #html
- [rule] Attachments download to a temp dir with sanitized filenames (strip path separators / control chars); app is sandboxed with outgoing-network only, user-selected read/write for save panels #sandbox

## Relations
- relates_to [[Herald Architecture]]

## Update (2026-08-15 — P0.6 security fixes as built)
- [rule] MessageWebView: `NavigationPolicy.decide` allows ONLY our initial about:blank main-frame load, opens `.linkActivated` http(s)/mailto externally, cancels everything else (iframes/forms/meta-refresh); `allowsLinkPreview=false`; wrapping document carries a locked-down CSP (`default-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'`, img-src widened to https/http only when the sender is trusted); rule list blocks ping/popup/websocket/fetch too #webview
- [rule] Sign-out POSTs RFC 7009 revocation (refresh token, best-effort) BEFORE deleting Keychain tokens; discovery rejects any endpoint not https on the origin's host (`OAuthError.untrustedEndpoints`) #oauth
- [rule] Never log `String(describing:)` of `OutboxError`/`MailAPIError` — use their payload-free `logCode` #logging
- [decision] REVERSED 2026-08-16: Herald uses the LOGIN keychain (no `kSecUseDataProtectionKeychain`, no `keychain-access-groups` entitlement). The data-protection keychain needs that entitlement, which needs a Developer ID provisioning profile, which Herald deliberately does not ship (yearly renewal, account-bound export). Items are still ACL-locked to Herald's signature and never marked synchronizable. Real-release finding: export demanded a profile; SecItem returned -34018 without it #keychain
- [fact] Saved attachments get `LSFileQuarantineEnabled` + explicit quarantineProperties; inside the sandbox the OS overrides the type with LSQuarantineTypeSandboxed (test asserts agent name only) #quarantine


## Update (2026-09-19 — audit F3: unreadable state is not absent state)

- [rule] A Keychain/`AccountStore` READ FAILURE must never be flattened into "nothing stored" (`try? store.tokens(for:) ?? nil`). The Keychain is the arbiter of which OAuth grant is live across processes, so a failed read that reads as "nobody rotated anything" sends the refresh on to spend a token another process may already have redeemed — and HQBase rotates with no reuse grace, so replaying one invalidates the whole family. `AccountTokenProvider.currentTokens()` logs and throws `OAuthError.transport` (retryable); the `invalid_grant` path refuses to clear the shared item on a read it could not make. The ONE sanctioned `try?` is the confirmation read AFTER a successful write, where throwing would send the caller back to re-spend the new grant #keychain #errors
- [rule] Bare `try?` on a store WRITE still logs: `setTokens(nil, …)` on a dead grant is best-effort, but a clear that silently failed leaves the dead grant on disk for the next launch to retry #errors
- [rule] An OAuth callback's `error` query value is attacker-reachable server free text and is never logged at `.public` verbatim — `OAuthSession.logName(forCallbackError:)` maps it to the RFC 6749 §4.1.2.1 set (plus `invalid_grant`) or `other`; the raw value travels only in the thrown `OAuthError.server` for the UI. Same shape as the payload-free `logCode` rule (audit P14) #logging #privacy
