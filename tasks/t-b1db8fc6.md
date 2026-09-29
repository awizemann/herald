---
id: t-b1db8fc6
title: WF2: AI Gateway settings page + privacy disclosure
status: done
added: 2026-09-29
priority: high
---

## Description

App target. New root Settings page "AI Gateway" (Herald group or own group): Account ID, Gateway ID, token SecureField → Keychain via WF1 store (show "saved" state, never echo), model picker = curated Workers AI list (default `@cf/qwen/qwen3-30b-a3b-fp8`; also llama-4-scout-17b-16e-instruct, llama-3.1-8b-instruct-fp8, mistral-small-3.1-24b-instruct) + Custom `@cf/...` text field. Non-secret settings in UserDefaults via injected-defaults static-func pattern (like NotificationSettings). "Test connection" button with plain-English error messages per WF1 error. Privacy page: disclosure that when classification is enabled, message sender/subject/text is sent to the configured Cloudflare AI Gateway. MailTheme tokens only; accessibility labels; follow settings window architecture note. Tests for settings persistence + route.

## Plan



## Artifacts

Commit 5aa2c3f on feature/workflows-classification (not pushed).
- Herald/Support/AIGatewaySettings.swift — keys, curated models, providerModel(for:), configuration(in:), isConfigured(in:secrets:), token save/remove (Keychain only), plain-English error messages.
- Herald/Views/Settings/SettingsAIGatewayPage.swift — page + AIGatewaySettingsModel.
- SettingsRoute.aiGateway (Herald group), AccessibilityID.Settings.aiGateway*, Privacy "Email classification" disclosure.
- HeraldTests/AIGatewaySettingsTests.swift — 10 tests (round trip, nil config, token not in defaults, custom model validation, test connection via URLProtocol stub, route, disclosure).
Results: app 703 tests pass, HeraldKit 492 pass, build succeeded. No UI tests added.

