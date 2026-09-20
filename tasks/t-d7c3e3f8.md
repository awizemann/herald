---
id: t-d7c3e3f8
title: 1.4 U4: Settings ▸ Signatures editor (signatures:manage)
status: done
added: 2026-09-19
---

## Description

Kit: SignatureManagementService over the U1 CRUD methods. App: Settings tab listing manageable signatures, create/edit (name, HTML body as plain field + live preview, scope user/mailbox/domain, default flag), delete. Hide with a hint when the token lacks signatures:manage (existing accounts until re-consent) or server 404s. MailTheme tokens, accessibility. Tests for view model + service. Depends on U1.

## Plan



## Artifacts

Branch `worktree-agent-a1fab3421d6fbe37c`, commit **3eee453** (rebased onto main @ 45b72a9, which the worktree was missing).

**Files**
- new `HeraldKit/Sources/HeraldKit/Compose/SignatureManagementService.swift` — actor + `SignatureManaging` protocol + `SignatureManagementError` + `SignatureScopeGroup`
- new `Herald/App/SignatureSettingsModel.swift` — `@MainActor @Observable` view model + `SignatureEditor` + `SignatureScopeOption`
- new `Herald/Views/SignatureSettingsView.swift` — pane, editor sheet, `SignaturePreviewView` (WKWebView)
- new tests `HeraldKit/Tests/HeraldKitTests/Compose/SignatureManagementServiceTests.swift`, `HeraldTests/SignatureSettingsTests.swift`
- modified `Herald/Views/SettingsView.swift` (tab, window 320→420pt), `Herald/App/AppEnvironment.swift` (service on `AccountGraph`, per-account pane model, `signatureRevision`, `reauthenticateSelectedAccount`), `Herald/Compose/ComposeWindow.swift` (candidate fetch keyed on the revision; `ComposeView` gained an OPTIONAL `@Environment(AppEnvironment.self)`)

**Tests** HeraldKit 318 → 330 (+12); app-hosted 255 → 271 (+16). All pass; build clean apart from 3 pre-existing warnings.

**Not verified**: no live run against localhost:8787 (skipped — would have needed re-registration with the new scope); no rendered-UI check (no screenshots); the preview web view and the `.task` debounce are untested (no view tests in this project).

**Upstream gap found**: `requireManageScope` rejects `scope.id != actor.id` for the `user` scope and no route exposes the caller's user id, so a user with zero personal signatures cannot create their first one from any API client. Herald hides "Personal" until an existing user-scoped signature reveals the id. Worth an upstream issue.

