# P0.6 audit fix list (verified by orchestrator; apply all, in this order)

Every item: fix + a discriminating test that fails on the old code. Cite the test in your report.

## Correctness / lifecycle (must fix)
1. **MailStore account scoping** — `cachedBody(messageID:)`, `storeBody`, `message(id:)`, `fetchMessage(id:)`, and both `applyLocalAction`/`revertLocalAction` paths must filter by `accountID` too (the #Unique is (accountID, messageID)). Change signatures to take `accountID`. Test: two accounts, same message id — body store and read action on one leaves the other untouched.
2. **AppEnvironment.activate leaks the previous SyncEngine + MailViewModel** (`Herald/App/AppEnvironment.swift` activate): call `mail?.stop()` and `await syncEngine?.stop()` before building the new graph (like signOut). Test: activate twice; the first fake API's call count stops growing.
3. **MailViewModel.reloadConversations reentrancy**: capture `let scope = selection` before the await; after it, `guard scope == selection, !Task.isCancelled else { return }`; cancel `reloadTask` before replacing in `selection.didSet`. Also `isLoadingBody` defer only clears if `selectedMessageID == messageID`. Test: flip selection twice with a slow fake store; final list matches final selection and selection is not dropped.
4. **OutboxService is documented as serializing but is reentrant**: add per-draft in-flight `Task` map so two concurrent `saveDraft` (or autosave + `attach`) on an unsaved draft create ONE server draft; `attach` joins it. Test: two concurrent saveDraft → createDraft count == 1.
5. **SyncEngine**: (a) generic catch: if `Task.isCancelled` (or error is `MailAPIError.transport(URLError.cancelled)`) return silently — no `.failed`, no backoff bump; (b) timer/wake race: add a `waitGeneration` counter; timer fires with its generation and is ignored if stale or if no continuation is parked. Tests: cancelled pass emits no `.failed`; a stale timer fire after refreshNow does not produce an extra pass (drive with zero-interval cadence + gate).
6. **AccountTokenProvider.refreshAccessToken(failedToken:)** — if the stored access token already differs from the one that 401'd, return it without refreshing. Middleware passes the token it used. Test: after one refresh completes, a late 401 with the old token does not call the token endpoint again.
7. **WebAuthenticationPresenter**: wrap the continuation in `withTaskCancellationHandler` cancelling the ASWebAuthenticationSession on main; resume via a main-actor method rather than `MainActor.assumeIsolated` in the callback.
8. **FakeMailAPIClient (kit) `perform(onMessage:)` must be able to succeed** (return an updated summary); add "successful message action sticks and does not revert" test. App fake must record the `folder` on conversation actions; add test that with `.archived` selected the VM sends `folder == .archived`.

## Security (must fix)
9. **MessageWebView navigation containment**: in `decidePolicyFor` allow only the initial about:blank main-frame load from our own loadHTMLString; cancel every other navigation (iframes, forms, meta refresh, `.other`), keep `.linkActivated` → NSWorkspace.open + cancel; set `allowsLinkPreview = false`. Inject a CSP `<meta http-equiv="Content-Security-Policy">` in the wrapping document: `default-src 'none'; img-src data: cid:` (+ `https: http:` only when remote is trusted) `; style-src 'unsafe-inline'; font-src data:; media-src data:; form-action 'none'; frame-src 'none'; base-uri 'none'`. Test: WKWebView in-process loads a doc with `<iframe src="https://127.0.0.1:1/">` and a form; delegate cancels both (record decisions).
10. **RemoteContentBlocker**: add resource types `ping`, `popup`, `websocket`, `fetch`; keep compile test; assert `ping` present.
11. **Sign-out revokes**: decode `revocation_endpoint` from metadata; `signOut` POSTs RFC 7009 revoke (token=refresh, token_type_hint=refresh_token, client_id) best-effort BEFORE removing tokens; failure logs a warning and removal proceeds. Test via FakeServer both paths. If the endpoint is absent, skip silently.
12. **Attachment quarantine**: set `LSFileQuarantineEnabled: true` in project.yml info.properties AND set `URLResourceValues.quarantineProperties` after `AttachmentSaver` writes (type email attachment). Test: after save, resource value present (skip if sandbox forbids in test).
13. **Log redaction**: never log `String(describing:)` of `OutboxError`/`MailAPIError` — add a payload-free `logCode` on both and log that (addresses/subjects/server messages are private). Sweep ComposeViewModel + OutboxService. Test: `OutboxError.invalidRecipient("a@b").logCode` does not contain "a@b".
14. **Inline images**: only substitute `cid:` when the payload MIME is image/*, video/*, audio/*; else skip.
15. **KeychainStore**: add `kSecUseDataProtectionKeychain: true` and `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (tests already skip Keychain when unavailable — keep that guard).
16. **OAuthDiscovery**: require issuer/authorization/token/registration endpoints to be https and share the origin's host; else `discoveryFailed`. Test with an off-origin metadata doc.

## Tests / hygiene
17. `SourceBoundaryTests`: `#require(!files.isEmpty)` and that it saw MailStore.swift.
18. `MailViewModelTests` dwell: `try #require(dwell)` instead of optional-await; add `.timeLimit` to the concurrent-refresh auth test and drop the read-count implementation assertion.
19. Remove checkbox tests (`HeraldAppTests.appTargetLinksKit`, `SmokeTests.moduleLoads`); replace HeraldAppTests with something real or delete the file if nothing else is in it (keep the target compiling — Swift Testing needs ≥1 test? no; but keep at least the VM tests there).
20. `nonisolated extension MailAPIClient` for the convenience overloads; also make the `LocalizedError` extensions nonisolated.
21. Wire test: PATCH /api/v1/drafts/{id} body contains `"version":N`; 409 `{error:{code:"DRAFT_CONFLICT"}}` maps to `.server(code:"DRAFT_CONFLICT")` and OutboxService retries once.
22. Corrupt-store test: also create a valid store with a different Schema at the URL and assert `make(url:)` yields a usable container AND replaced the file (mtime/inode) and removed -wal/-shm.
23. `#Index` column order: `[accountID, listFolder, mailboxKey]` / `[accountID, folderRaw, mailboxKey]` (+ `sortDate` trailing) so mailbox-nil queries are prefix-served.

Deferred (ticketed, not in this pass): optimistic-vs-sync fence (pending-mutation set in MailStore), Keychain I/O off main, PrivacyInfo.xcprivacy, per-draft attachment total cap.
