---
created: 2026-09-29
updated: 2026-09-29
source_sha: 2bfa6bee79e5baf669c80ee8cf23b74d74feaead
source_paths: Herald/App
source_paths_inferred: false
---

# App Environment

AppEnvironment is Herald's composition root: it holds the per-account object graph, coordinates sign-in/sign-out, and routes UI state to the right account.

## Structure

**AppEnvironment** (final class, @MainActor)
- `accounts: [Account]` — stable list of signed-in accounts (from KeychainAccountStore).
- `graphs: [Account.ID: AccountGraph]` — one sync engine, MailViewModel, OutboxService, NewMailNotifier per account.
- `phase: Phase` — enum `signedOut | signingIn(stage: SignInStage) | ready | error(String)`.
- `selectedAccountID: Account.ID` — which account the user is viewing (drives which graph's data flows to the UI).

**AccountGraph** (final class)
- Instantiated when an account signs in; torn down on sign-out.
- Contains `SyncEngine`, `MailViewModel`, `OutboxService`, `NewMailNotifier` — all wired together.

**ComposeSession** (struct)
- Tracks an open compose window: `id`, `mode` (reply/forward/new), `draftID`, `fromAddress`.
- Stored in AppEnvironment so compose persists across account switches (you can edit a reply while checking another account).

**AutoReauthPolicy** (struct)
- Detects expired sessions (a 401 from the API, or a failed token refresh) and re-runs sign-in by itself, rate-limited to frontmost app. See [[automatic-re-auth-policy-frontmost-deferred-rate-limited]].

## Key flow

1. Launch → check Keychain → if accounts exist, pick the first → instantiate its AccountGraph → `phase = .ready`.
2. User switches to another account → tear down old graph → instantiate new one → update `selectedAccountID` (views re-render).
3. Session expires → AutoReauthPolicy fires → phase moves to `.signingIn` → banner appears → once signed back in, phase = `.ready`.
4. User opens a new compose → store it in `composeSession` → it survives account switches.

## When you touch this

- Adding app-wide state (e.g., a global setting)? Put it on AppEnvironment.
- Wiring up a new per-account service (e.g., search index)? Build it in AccountGraph and inject via AppEnvironment.
- Changing account-switch behavior? Edit `selectAccount(_:)` and watch for edge cases around open compose windows.
