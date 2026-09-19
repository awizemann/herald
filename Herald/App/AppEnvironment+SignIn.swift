import Foundation
import HeraldKit
import OSLog

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "AppEnvironment")

/// Onboarding, re-authentication and sign-out: everything that adds an account to
/// ``AppEnvironment`` or takes one away. Split out of `AppEnvironment.swift`
/// verbatim; the stored state these read and write stays on the main declaration,
/// which is why that state is `internal` rather than `private`.
extension AppEnvironment {
    // MARK: - Onboarding

    /// Validates an origin the user typed. `nil` means "not a usable origin".
    nonisolated static func normalizedOrigin(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return Account.normalize(url)
    }

    /// Runs one interactive sign-in, retaining the task so it can be cancelled.
    ///
    /// Awaited by the caller so tests (and the view's task) still see it through,
    /// but the work lives in the retained handle: cancelling the view's task would
    /// otherwise leave the real sign-in running with nothing observing it.
    func signIn(originText: String) async {
        let generation = beginInteractiveSignIn()
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await self.performSignIn(originText: originText, generation: generation)
            self.record(.accountAdded(outcome: result.outcome, kind: result.kind))
        }
        signInCancellation = { task.cancel() }
        await task.value
        // Only if nothing has taken the sign-in over since (a cancel, or the
        // attempt the user started right after it).
        if signInGeneration == generation { signInCancellation = nil }
    }

    /// Claims the sign-in UI for a new interactive attempt and returns its ticket.
    ///
    /// Whatever held the claim is CANCELLED first, not merely orphaned: the two
    /// entry points can interleave (the re-auth banner clicked while an Add
    /// Account sheet is signing in, or the reverse), and a dropped handle would
    /// leave a browser window open that nothing could close.
    private func beginInteractiveSignIn(reauthenticating accountID: Account.ID? = nil) -> Int {
        cancelInteractiveSignIn()
        signInGeneration &+= 1
        signInReauthAccountID = accountID
        return signInGeneration
    }

    /// Cancels the attempt that currently holds the claim and releases anything
    /// it was holding open on its behalf. Does NOT touch the visible state — the
    /// callers differ on that.
    private func cancelInteractiveSignIn() {
        signInCancellation?()
        signInCancellation = nil
        // A re-auth attempt claimed this account in `AutoReauthPolicy` and only
        // releases it when its task returns — which, for the stall this whole
        // change is about, may be never. Releasing it here is what keeps the
        // banner from reading "Signing you back in…" forever with a dead retry
        // button behind it.
        if let accountID = signInReauthAccountID {
            autoReauth.finish(accountID: accountID, succeeded: false)
            signInReauthAccountID = nil
        }
    }

    /// Abandons the running interactive sign-in and gives the screen back.
    ///
    /// Two separate jobs, because they can fail independently: cancelling the task
    /// (which unwinds a presenter that honours cancellation) AND clearing the UI
    /// state right here. The second is what makes the reported hang survivable —
    /// a step that cannot be interrupted at all (a blocked `SecItem` call, an
    /// authentication agent that never answers) still leaves the user with a
    /// usable window and a working second attempt.
    ///
    /// Automatic re-auth is untouched: it never sets this state and its attempts
    /// are tracked separately, so a user cancelling a manual sign-in cannot
    /// abort a background repair, and vice versa.
    func cancelSignIn() {
        guard isSigningIn else { return }
        logger.info("sign-in cancelled by the user at stage \(self.signInStage?.logName ?? "none", privacy: .public)")
        // Orphans the attempt in flight: whatever it does from here cannot touch
        // the sign-in UI or install an account.
        signInGeneration &+= 1
        cancelInteractiveSignIn()
        isSigningIn = false
        signInStage = nil
        signInError = nil
    }

    /// Publishes a stage, if the attempt reporting it still owns the screen.
    private func setSignInStage(_ stage: SignInStage, generation: Int?) {
        guard ownsSignInUI(generation) else { return }
        signInStage = stage
        logger.info("sign-in stage: \(stage.logName, privacy: .public)")
    }

    /// Whether this attempt is still the one the sign-in UI belongs to. `nil` is
    /// an automatic attempt, which never owns it.
    private func ownsSignInUI(_ generation: Int?) -> Bool {
        generation != nil && generation == signInGeneration
    }

    /// What one sign-in round trip produced. The ACCOUNT matters to re-auth: the
    /// same origin can come back under a different id, and only the returned
    /// account says so.
    private struct SignInResult {
        var outcome: UsageAccountOutcome
        var kind: UsageOAuthErrorKind?
        var account: Account?
    }

    /// The sign-in flow itself, reduced to the two values an event may carry.
    /// Shared by ``signIn(originText:)`` and ``reauthenticate(accountID:)`` so the
    /// same round trip is never reported as both an add AND a re-auth.
    /// - Parameter generation: the interactive attempt's ticket, or `nil` for an
    ///   attempt Herald started by itself. An automatic attempt leaves
    ///   `isSigningIn`, `signInStage`, `signInError` and `presentsAddAccount`
    ///   alone: nothing asked for the onboarding sheet, and a failure must land on
    ///   the re-auth banner that is already up rather than raising sheet state
    ///   over the mail the user is reading. A stale generation — the user
    ///   cancelled — behaves the same way, and additionally refuses to install.
    private func performSignIn(
        originText: String,
        generation: Int? = nil
    ) async -> SignInResult {
        let isAutomatic = generation == nil
        guard let origin = Self.normalizedOrigin(from: originText) else {
            if ownsSignInUI(generation) {
                signInError = "Enter the https address of your HQBase server, for example https://mail.example.com"
            }
            // A typo in the address field, not an OAuth fault: there is no kind
            // to report, and the text the user typed is never one.
            return SignInResult(outcome: .failed)
        }
        if ownsSignInUI(generation) {
            isSigningIn = true
            signInStage = nil
            signInError = nil
        }
        // Runs on every exit INCLUDING cancellation — but only clears state this
        // attempt still owns, so a cancel that already reset the screen (and a
        // second attempt started behind it) is not undone here.
        defer {
            if ownsSignInUI(generation) {
                isSigningIn = false
                signInStage = nil
            }
        }
        do {
            let account = try await auth.addAccount(origin: origin) { [weak self] step in
                self?.setSignInStage(SignInStage(step), generation: generation)
            }
            // Consent finished, but the user may have given up while the browser
            // window was open. Installing now would drag them into a mailbox they
            // just cancelled out of.
            guard isAutomatic || ownsSignInUI(generation), !Task.isCancelled else {
                logger.info("sign-in completed after it was cancelled; undoing it")
                // `addAccount` has ALREADY written the account and its tokens to
                // the Keychain. Leaving them there would make Cancel a merely
                // deferred sign-in: the next launch would restore the account and
                // open the mailbox the user walked away from. Signing it back out
                // also revokes the refresh token, which is the right end for
                // consent nobody wanted.
                do {
                    try await auth.signOut(account)
                } catch {
                    logger.error("could not undo a cancelled sign-in: \(error.localizedDescription, privacy: .private)")
                }
                return SignInResult(outcome: .cancelled)
            }
            if ownsSignInUI(generation) {
                presentsAddAccount = false
                signInStage = .activating
            }
            // Consent alone is not a signed-in account: an activation that fails
            // (unreachable server, unreadable tokens) leaves the user exactly as
            // stuck as before, and reporting it as a success would also clear the
            // automatic attempt's cooldown for a repair that did not happen.
            let activated = await activate(account, isAutomatic: isAutomatic)
            return SignInResult(
                outcome: activated ? .success : .failed,
                kind: activated ? nil : .other,
                account: activated ? account : nil
            )
        } catch {
            logger.warning("Sign-in failed: \(error.localizedDescription, privacy: .private)")
            if ownsSignInUI(generation) { signInError = error.localizedDescription }
            // A failure that is not an `OAuthError` still failed: it counts as
            // `other` rather than being dropped, and carries nothing of itself.
            let kind = UsageOAuthErrorKind(anyError: error)
            // Closing the browser window is a choice, not a failure.
            return kind == .cancelled
                ? SignInResult(outcome: .cancelled)
                : SignInResult(outcome: .failed, kind: kind)
        }
    }

    /// Re-runs the whole flow for the ONE account whose token died. The other
    /// accounts keep syncing throughout.
    func reauthenticate(accountID: Account.ID?) async {
        guard let accountID, let account = graphs[accountID]?.account else {
            if graphs.isEmpty { phase = .signedOut }
            return
        }
        // A button press outranks the frontmost rule and the cooldown — the user
        // is standing there — but not the one-window rule: clicking while an
        // automatic attempt is running would open a second consent window over
        // the first.
        guard autoReauth.beginUserInitiated(accountID: accountID) else { return }
        // Retained and generation-stamped like a first sign-in: a re-auth is just
        // as capable of stalling in the browser hand-off, and the banner's spinner
        // has to be escapable too — the banner shows Cancel while
        // ``isSigningIn`` and it lands on ``cancelSignIn()``.
        let generation = beginInteractiveSignIn(reauthenticating: accountID)
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.runReauthentication(account: account, generation: generation)
        }
        signInCancellation = { task.cancel() }
        let succeeded = await task.value
        // A cancel (or a second attempt) already released the policy claim and
        // moved the generation on; finishing again here would write a stale
        // result over whatever now owns the account.
        guard signInGeneration == generation else { return }
        signInCancellation = nil
        signInReauthAccountID = nil
        autoReauth.finish(accountID: accountID, succeeded: succeeded)
    }

    /// Whether the re-auth running for this account is the USER's, and therefore
    /// has a Cancel to offer. False for an automatic attempt (nobody asked for it,
    /// and it withdraws by itself) and for a sign-in belonging to another account
    /// or to the Add Account sheet.
    func isCancellableReauthentication(accountID: Account.ID) -> Bool {
        isSigningIn && signInReauthAccountID == accountID
    }

    /// Whether a re-auth round trip is running for this account. The banner stays
    /// up and says so, rather than offering a button that would open a second
    /// authorization window over the first.
    func isReauthenticating(accountID: Account.ID) -> Bool {
        autoReauth.isAttempting(accountID: accountID)
    }

    /// Re-runs consent WITHOUT waiting for the banner to be clicked, when the
    /// rules in ``AutoReauthPolicy`` allow it.
    ///
    /// HQBase binds Herald's tokens to the user's web session (7-day sliding), so
    /// tokens die on a schedule that has nothing to do with anything the user
    /// did. While that web session is still alive the consent page completes on
    /// its own, so the whole repair is a window that flashes — worth doing for
    /// the user, and only when they are actually here to see it.
    ///
    /// Scoped to the account the window is SHOWING. An account syncing behind the
    /// window would have its sign-in select it (`install(select:)` follows a
    /// sign-in), pulling the user off the mail they are reading; the others keep
    /// the banner until ``retryAutomaticReauthentication()`` picks them up —
    /// which is also how a session that died while Herald was in the background
    /// (the common case: the binding expires on a 7-day timer) is repaired the
    /// moment the user comes back.
    func attemptAutomaticReauthentication(accountID: Account.ID) async {
        guard accountID == selectedAccountID, let account = graphs[accountID]?.account else { return }
        guard graphs[accountID]?.mail.status == .needsReauth else { return }
        guard autoReauth.begin(
            accountID: accountID,
            isApplicationActive: isApplicationActive()
        ) else { return }
        // Held so a sign-out can CANCEL the attempt: its `install` would
        // otherwise land after the account was removed and bring it — and its
        // window selection — straight back.
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.runReauthentication(account: account, generation: nil)
        }
        automaticReauthTasks[accountID] = task
        let succeeded = await task.value
        automaticReauthTasks[accountID] = nil
        autoReauth.finish(accountID: accountID, succeeded: succeeded)
    }

    /// Re-offers the automatic repair for whatever the window is showing.
    ///
    /// The gates in ``attemptAutomaticReauthentication(accountID:)`` DEFER, they
    /// do not consume: the expiry is announced once, by the sync pass that found
    /// it, and that pass usually runs while Herald is in the background or on an
    /// account the window is not showing. Herald becoming frontmost and the user
    /// switching accounts are the two moments a deferred repair becomes possible.
    func retryAutomaticReauthentication() async {
        guard let accountID = selectedAccountID else { return }
        await attemptAutomaticReauthentication(accountID: accountID)
    }

    /// The re-auth round trip both entry points share. Returns whether the
    /// account is signed in again.
    private func runReauthentication(account: Account, generation: Int?) async -> Bool {
        let isAutomatic = generation == nil
        let accountID = account.id
        let result = await performSignIn(
            originText: account.origin.absoluteString,
            generation: generation
        )
        record(.accountReauthenticated(
            outcome: result.outcome,
            kind: result.kind,
            automatic: isAutomatic
        ))
        // The same origin can come back under a DIFFERENT id (a different user
        // signed in). `install` then keys the new graph elsewhere and the dead
        // one would be left polling with a token nothing can refresh. Decided on
        // the id the sign-in actually returned — the selection can move for
        // reasons that have nothing to do with this round trip (the user clicking
        // another account while an automatic attempt runs), and tearing an account
        // down for that would drop a healthy account out of the switcher.
        if let signedIn = result.account, signedIn.id != accountID {
            await stopGraph(accountID: accountID)
            accountIDs.removeAll { $0 == accountID }
            autoReauth.forget(accountID: accountID)
        }
        return result.outcome == .success
    }

    /// Signs ONE account out: its graph stops, its cached rows are purged, and
    /// the window falls back to whatever account is left.
    func signOut(accountID: Account.ID?) async {
        guard let accountID else { return }
        // BEFORE any suspension: the launch restore may still have this account
        // queued behind a slower one, and an activation that started after the
        // removal would re-install it with a live engine (audit C10).
        cancelPendingRestore(accountID: accountID)
        // An account whose graph never came up (its server was unreachable at
        // launch) is still signed in as far as the Keychain is concerned, so the
        // account list is the fallback — otherwise it could never be removed.
        var resolved = graphs[accountID]?.account
        if resolved == nil {
            resolved = (try? await auth.loadAccounts())?.first { $0.id == accountID }
        }
        guard let account = resolved else { return }
        // An INTERACTIVE re-auth for this account would `install` it again — with
        // a graph and the window selection — right after the sign-out removed it.
        // Its automatic sibling is cancelled and awaited just below; this one is
        // only cancelled, because the whole point of the handle is that its task
        // may never return.
        if signInReauthAccountID == accountID {
            signInGeneration &+= 1
            cancelInteractiveSignIn()
            isSigningIn = false
            signInStage = nil
        }
        // An automatic attempt still running would `install` this account again —
        // selecting it — right after the sign-out removed it. Cancelled AND
        // waited for, so nothing of it can land behind the removal.
        if let attempt = automaticReauthTasks.removeValue(forKey: accountID) {
            attempt.cancel()
            _ = await attempt.value
        }
        record(.accountRemoved)
        // Signing back in later must not inherit the dead session's cooldown.
        autoReauth.forget(accountID: accountID)
        await stopGraph(accountID: accountID)
        accountIDs.removeAll { $0 == accountID }
        // The window settles BEFORE the slow half. Revocation is a network round
        // trip and the purge is a store write; leaving `selectedAccountID`
        // pointing at a graph that is already gone renders a launch placeholder
        // over the surviving account, and a switcher whose selection has no tag.
        // A fallback, not a switch: `account_removed` already said what happened.
        if selectedAccountID == accountID { selectAccount(accountIDs.first) }
        if graphs.isEmpty { phase = .signedOut }
        do {
            try await auth.signOut(account)
        } catch {
            logger.error("Sign-out failed: \(error.localizedDescription, privacy: .private)")
            signInError = error.localizedDescription
        }
        // Signing the same origin back in during the revoke round trip would
        // otherwise have its freshly synced rows deleted underneath it.
        guard graphs[accountID] == nil, let store else { return }
        do {
            // Scoped to this account: the other accounts' rows share the
            // container and must survive.
            try await store.deleteAll(accountID: accountID)
        } catch {
            logger.error("Cache purge failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
