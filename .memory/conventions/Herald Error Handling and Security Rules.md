---
title: Herald Error Handling and Security Rules
type: note
permalink: hqbase-mac/conventions/herald-error-handling-and-security-rules
tags:
- errors
- security
created: 2026-08-16
updated: 2026-08-16
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
