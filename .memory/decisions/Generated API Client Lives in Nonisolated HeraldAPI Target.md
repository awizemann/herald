---
title: Generated API Client Lives in Nonisolated HeraldAPI Target
type: note
permalink: hqbase-mac/decisions/generated-api-client-lives-in-nonisolated-heraldapi-target
tags: [decision, openapi, concurrency]
created: 2026-08-16
updated: 2026-09-19
---

## Observations
- [decision] The swift-openapi-generator output (Types/Client for the vendored HQBase v1 spec) is isolated in its own SPM target `HeraldAPI` that builds WITHOUT `.defaultIsolation(MainActor.self)`; `HeraldKit` (default-MainActor) depends on it and wraps it behind `MailAPIClient` — generated types never reach the app #layout
- [gotcha] Under default-MainActor isolation the generated multipart payload's `Hashable` conformance becomes main-actor-isolated and fails "cannot satisfy conformance requirement for a 'Sendable' type parameter" (Swift 6.4 / Xcode 27b, generator 1.7); do NOT "fix" by moving the plugin into HeraldKit or adding defaultIsolation to HeraldAPI #isolated-conformance
- [gotcha] `accessModifier: package` in openapi-generator-config.yaml collides with implicit `import Foundation` ("ambiguous implicit access level for import") — use `public` (leaf target consumed by HeraldKit) #access
- [gotcha] Generator 1.7 does NOT support OAS 3.1 nullable (`anyOf:[S,{type:null}]`) — it DROPS the whole property (readAt/starredAt/mailboxId/nextCursor/… vanished). `scripts/vendor-openapi.py` rewrites those to plain optional schemas; run it after every spec refresh; the DTO mapping tests fail if a field is dropped again #nullable
- [fact] Refresh the spec: overwrite HeraldKit/Sources/HeraldAPI/openapi.json from upstream `api/hqbase-mail-api-v1.openapi.json` THEN run `python3 scripts/vendor-openapi.py`; a compile break in HeraldKit's wrapper is the intended contract-drift signal #refresh

## Relations
- relates_to [[Herald Architecture]]
- relates_to [[HQBase Mail API v1 Contract]]

## Update (2026-08-15 — P0.1 findings)
- [gotcha] HQBase timestamps are JS `toISOString()` (fractional seconds); OpenAPIRuntime's default date transcoder rejects them — `HQBaseDateTranscoder` (accepts both) is passed via `Client(configuration:)`. Removing it breaks every date-bearing response. #dates
- [decision] All HTTP error mapping happens in `AuthenticatingMiddleware` (bearer inject, one refresh+retry on 401 invalid_token, ≥400 → `MailAPIError` from `{error:{code,message}}` + WWW-Authenticate scope) so the generated client only ever sees success cases; per-operation `default:` branches are unreachable by construction #errors


## Update (2026-09-19 — second generator workaround in the vendor script)

- [gotcha] Generator 1.7 also mishandles an "AT LEAST ONE OF" object: a schema with its own `properties` PLUS a top-level `anyOf:[{required:[a]},{required:[b]}]` is read as N separate schemas. Each branch names a property it does not itself declare, so the generator warns "A property name only appears in the required list … skipping this property" and emits N EMPTY structs — the real fields VANISH and the type encodes `{}`. Hit by `UpdateSignatureInput` at spec v1.4.2 (PATCH /signatures/{id}); every signature edit would have 400'd. `scripts/vendor-openapi.py` now drops such an `anyOf`, leaving a plain all-optional object, and the rule becomes a client-side guard (`UpdateSignatureInput.isEmpty`) #at-least-one-of
- [check] After every spec regen, read the plugin's warnings, not just the compile result: "skipping this property" is the generator DROPPING a field, and nothing downstream fails to build — `Upstream142AdoptionTests` asserts the PATCH body actually carries its fields for exactly that reason #guards
