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
            let result = await self.performSignIn(
                originText: originText,
                generation: generation,
                refusesExistingOrigin: true
            )
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
        abandonInteractiveSignIn()
    }

    /// The body of ``cancelSignIn()``, without its `isSigningIn` gate: a
    /// user-initiated re-auth claims the account synchronously but only raises
    /// `isSigningIn` once its task starts, and the banner's Cancel must work in
    /// that gap too.
    private func abandonInteractiveSignIn() {
        logger.info("sign-in cancelled by the user at stage \(self.signInStage?.logName ?? "none", privacy: .public)")
        // Read before `cancelInteractiveSignIn` releases it.
        let reauthenticating = signInReauthAccountID
        // Orphans the attempt in flight: whatever it does from here cannot touch
        // the sign-in UI or install an account.
        signInGeneration &+= 1
        cancelInteractiveSignIn()
        isSigningIn = false
        signInStage = nil
        // A cancel is not an error. The onboarding sheet's slot is Add
        // Account's; a re-auth's reason lives per account.
        if let reauthenticating {
            reauthErrors[reauthenticating] = nil
        } else {
            signInError = nil
        }
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
        /// Why a `.failed` round trip failed, as the user should read it. For a
        /// re-auth, which has no onboarding sheet to show it on.
        var failureReason: String?
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
    /// - Parameter refusesExistingOrigin: Add Account only (see
    ///   ``existingAccount(for:)``). Re-auth deliberately signs an existing
    ///   origin in again, so it passes `false`.
    /// - Parameter isReauthentication: a repair of an account already here.
    ///   Its failure goes back in ``SignInResult/failureReason`` (for
    ///   ``reauthErrors``), never into `signInError`: the onboarding sheet is
    ///   not what the user is looking at, and a message left there surfaced,
    ///   stale, in the next Add Account (audit W5).
    private func performSignIn(
        originText: String,
        generation: Int? = nil,
        refusesExistingOrigin: Bool = false,
        isReauthentication: Bool = false
    ) async -> SignInResult {
        let isAutomatic = generation == nil
        // Whether a failure may be written into the onboarding sheet — asked at
        // the moment of writing, since the generation can move meanwhile.
        func ownsOnboardingError() -> Bool { ownsSignInUI(generation) && !isReauthentication }
        guard let origin = Self.normalizedOrigin(from: originText) else {
            if ownsOnboardingError() {
                signInError = "Enter the https address of your HQBase server, for example https://mail.example.com"
            }
            // A typo in the address field, not an OAuth fault: there is no kind
            // to report, and the text the user typed is never one.
            return SignInResult(outcome: .failed)
        }
        if ownsSignInUI(generation) {
            isSigningIn = true
            signInStage = nil
        }
        if ownsOnboardingError() { signInError = nil }
        // Runs on every exit INCLUDING cancellation — but only clears state this
        // attempt still owns, so a cancel that already reset the screen (and a
        // second attempt started behind it) is not undone here.
        defer {
            if ownsSignInUI(generation) {
                isSigningIn = false
                signInStage = nil
            }
        }
        if refusesExistingOrigin, let refusal = await addAccountRefusal(for: origin) {
            // The check suspended (a Keychain read): the user may have cancelled.
            guard ownsSignInUI(generation), !Task.isCancelled else { return SignInResult(outcome: .cancelled) }
            signInError = refusal
            logger.info("Add Account refused before OAuth")
            // Not an OAuth fault — nothing was attempted — so no kind.
            return SignInResult(outcome: .failed)
        }
        do {
            let account = try await auth.addAccount(origin: origin) { [weak self] step in
                self?.setSignInStage(SignInStage(step), generation: generation)
            }
            // Consent finished, but the user may have given up while the browser
            // window was open. Installing now would drag them into a mailbox they
            // just cancelled out of.
            // Whether anybody still wants this round trip: an automatic attempt
            // is abandoned by cancelling its task (the banner's Cancel, a
            // sign-out), an interactive one by losing its generation.
            func isStillWanted() -> Bool {
                (isAutomatic || ownsSignInUI(generation)) && !Task.isCancelled
            }
            guard isStillWanted() else {
                await discardAbandonedSignIn(account)
                return SignInResult(outcome: .cancelled)
            }
            // The Add Account sheet stays up through activation and closes only
            // once the account is INSTALLED (below): closed here, an activation
            // failure had no screen to land on — its message went to a sheet
            // that was already gone, and the sheet's own didSet cleared it on
            // the next open (P9b, item G).
            if ownsSignInUI(generation) { signInStage = .activating }
            // Consent alone is not a signed-in account: an activation that fails
            // (unreachable server, unreadable tokens) leaves the user exactly as
            // stuck as before, and reporting it as a success would also clear the
            // automatic attempt's cooldown for a repair that did not happen.
            // Selected only when the account is NEW here. A re-auth never
            // takes the window: the user may be reading another account while
            // Herald (or a composer's Sign In) repairs this one, and the
            // selection is theirs. `install` still selects when nothing is
            // showing at all.
            let activation = await activateAccount(
                account,
                select: graphs[account.id] == nil,
                isStillWanted: isStillWanted
            )
            switch activation {
            case .installed:
                if ownsSignInUI(generation), !isReauthentication { presentsAddAccount = false }
                return SignInResult(outcome: .success, account: account)
            case .abandoned:
                // Activation suspends before it installs, and a cancel landing
                // in that gap is the same late consent as one landing before it.
                await discardAbandonedSignIn(account)
                return SignInResult(outcome: .cancelled)
            case .failed(let error):
                if !isStillWanted() {
                    await discardAbandonedSignIn(account)
                    return SignInResult(outcome: .cancelled)
                }
                // With nothing else up, `activateAccount` already ended the
                // launch on `.failed`; otherwise the sheet (Add Account) or the
                // re-auth's own reason says what went wrong.
                if ownsOnboardingError(), !graphs.isEmpty { signInError = error.localizedDescription }
                return SignInResult(outcome: .failed, kind: .other, failureReason: error.localizedDescription)
            }
        } catch {
            logger.warning("Sign-in failed: \(error.localizedDescription, privacy: .private)")
            if ownsOnboardingError() { signInError = error.localizedDescription }
            // A failure that is not an `OAuthError` still failed: it counts as
            // `other` rather than being dropped, and carries nothing of itself.
            let kind = UsageOAuthErrorKind(anyError: error)
            // Closing the browser window is a choice, not a failure.
            return kind == .cancelled
                ? SignInResult(outcome: .cancelled)
                : SignInResult(outcome: .failed, kind: kind, failureReason: error.localizedDescription)
        }
    }

    /// Why Add Account must not run for `origin`, as the text the onboarding
    /// sheet shows — or `nil` to go ahead.
    ///
    /// Two reasons, both checked BEFORE the browser opens (a refusal after
    /// consent would strand a freshly minted grant):
    /// - The origin is already signed in (``existingAccount(for:)``).
    /// - The Keychain account list cannot be read: the store would refuse to
    ///   save the new account anyway (``AccountStoreError/indexUnreadable``).
    ///
    /// Any OTHER failure to read the list (a Keychain error) does not block:
    /// the sign-in's own save surfaces it.
    private func addAccountRefusal(for origin: URL) async -> String? {
        let stored: [Account]
        do {
            stored = try await auth.loadAccounts()
        } catch AccountStoreError.indexUnreadable {
            return AccountStoreError.indexUnreadable.localizedDescription
        } catch {
            stored = []
        }
        guard let existing = existingAccount(for: origin, stored: stored) else { return nil }
        let host = existing.origin.host ?? existing.origin.absoluteString
        return "You're already signed in to \(host). If its session has expired, use Sign In on that account instead."
    }

    /// The account already signed in to `origin`, if any — live here, or only in
    /// the Keychain index `stored` (still queued behind the launch restore, or
    /// one whose activation did not come up).
    ///
    /// Why Add Account refuses one (audit W1): an account IS its origin today,
    /// so a second sign-in to the same server — possibly as a DIFFERENT user —
    /// would replace the existing account's grant under the same id, rebind its
    /// open composers to the other user and mix two mailboxes in one cache. The
    /// re-auth paths never come through here. Origins compare case-insensitively
    /// on scheme and host: `MAIL.example.com` is the same server.
    private func existingAccount(for origin: URL, stored: [Account]) -> Account? {
        let key = Self.originKey(origin)
        if let live = graphs.values.first(where: { Self.originKey($0.account.origin) == key }) {
            return live.account
        }
        return stored.first { Self.originKey($0.origin) == key }
    }

    /// Scheme, host and port, lowercased, with the default https port and a
    /// trailing root dot dropped (`https://x.com:443` and `https://x.com.` are
    /// `https://x.com`) — for COMPARING origins only. Never a key: account ids
    /// and Keychain keys keep `Account.normalize`, or existing items would be
    /// orphaned.
    nonisolated static func originKey(_ origin: URL) -> String {
        guard var components = URLComponents(url: Account.normalize(origin), resolvingAgainstBaseURL: false) else {
            return Account.normalize(origin).absoluteString.lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        if components.scheme == "https", components.port == 443 { components.port = nil }
        if var host = components.host?.lowercased() {
            while host.hasSuffix(".") { host.removeLast() }
            components.host = host
        }
        return (components.url ?? origin).absoluteString.lowercased()
    }

    /// What to do with a consent that completed after its attempt was abandoned.
    ///
    /// `addAccount` has ALREADY written the account and its tokens to the
    /// Keychain by the time the cancel is seen. Two cases, told apart by whether
    /// the account is signed in HERE right now:
    ///
    /// - A NEW account (an Add Account the user cancelled, a re-auth that came
    ///   back under a different id, or an account signed out while its re-auth
    ///   was running): signed back out. Leaving it would make Cancel a merely
    ///   deferred sign-in — the next launch would restore the account and open
    ///   the mailbox the user walked away from — and the sign-out also revokes
    ///   the refresh token, the right end for consent nobody wanted.
    /// - An account that is ALREADY signed in (the re-auth case, or Add Account
    ///   for an origin that is already here — the id is the origin): the new
    ///   grant is KEPT, and the account is re-installed on it WITHOUT being
    ///   selected. Signing out would delete the user's existing account from
    ///   the Keychain (it shares the id), so the Cancel of a repair would lose
    ///   the account outright at the next launch. Discarding only the new
    ///   tokens is no better: the grant they replaced is the dead one, so the
    ///   account would be exactly as broken as before. Kept but NOT installed
    ///   (P3) left the UI lying: the account worked, yet the banner and the
    ///   composers' Sign In still said it was dead, and once the cancel's
    ///   cooldown ran out the automatic attempt flashed a consent window for a
    ///   healthy account. Re-installing clears all of that the way a normal
    ///   sign-in does (fresh graph, sync restarted, composers rebound) — and
    ///   leaves the window where the user put it.
    ///
    /// A sign-out racing the late consent still wins either way: it removes the
    /// graph before it revokes, so the consent either lands after the graph is
    /// gone (signed out here) or finds it gone by the time the re-install would
    /// publish (``activate``'s `isStillWanted`), and the sign-out's own revoke
    /// and removal clear the grant.
    private func discardAbandonedSignIn(_ account: Account) async {
        if graphs[account.id] != nil {
            logger.info("re-auth consent completed after it was cancelled; keeping the new grant and re-installing without selecting")
            // In a task of its own: this runs inside the attempt the user
            // CANCELLED, and the install (discovery if uncached, the new
            // graph's start) must not inherit that cancellation. Awaited, so
            // the attempt returns with the account already back.
            // A failure is only logged: nobody is waiting on this activation.
            let revive = Task { [weak self] in
                guard let self else { return }
                await self.activate(account, select: false) { [weak self] in
                    self?.graphs[account.id] != nil
                }
            }
            await revive.value
            return
        }
        logger.info("sign-in completed after it was cancelled; undoing it")
        // In a task of its own for the same reason as the re-install above:
        // this runs inside the CANCELLED attempt, and the revocation is a
        // network request — cancelled with it, the new refresh token would be
        // deleted locally but stay live on the server.
        let undo = Task { [auth] in
            do {
                try await auth.signOut(account)
            } catch {
                logger.error("could not undo a cancelled sign-in: \(error.localizedDescription, privacy: .private)")
            }
        }
        await undo.value
    }

    /// Re-runs the whole flow for the ONE account whose token died. The other
    /// accounts keep syncing throughout.
    /// - Parameter fromComposer: the attempt is a compose window's Sign In. That
    ///   window announces the attempt's failure itself (it is where the user is),
    ///   so the re-auth banner — which may be showing the same account — stays
    ///   quiet about it rather than VoiceOver hearing one failure twice.
    func reauthenticate(accountID: Account.ID?, fromComposer: Bool = false) async {
        guard let accountID, let account = graphs[accountID]?.account else {
            if graphs.isEmpty { phase = .signedOut }
            return
        }
        // A button press outranks the frontmost rule and the cooldown — the user
        // is standing there — but not the one-window rule: clicking while an
        // automatic attempt is running would open a second consent window over
        // the first.
        guard autoReauth.beginUserInitiated(accountID: accountID) else { return }
        setReauthFailureAnnouncedByComposer(fromComposer, accountID: accountID)
        // A new attempt: the last one's reason no longer describes anything.
        reauthErrors[accountID] = nil
        // Retained and generation-stamped like a first sign-in: a re-auth is just
        // as capable of stalling in the browser hand-off, and the banner's spinner
        // has to be escapable too — the banner's Cancel lands on
        // ``cancelReauthentication(accountID:)``, which abandons it like
        // ``cancelSignIn()`` does.
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

    /// The re-auth banner's Cancel: stops whichever attempt is running for this
    /// account, the user's or Herald's own.
    ///
    /// Dispatched on `signInReauthAccountID` rather than `isSigningIn`: a
    /// user-initiated attempt holds the account from the moment it is claimed,
    /// before its task has raised `isSigningIn`.
    func cancelReauthentication(accountID: Account.ID) {
        // A cancel is not a failure: nothing to explain afterwards.
        reauthErrors[accountID] = nil
        if signInReauthAccountID == accountID {
            abandonInteractiveSignIn()
        } else {
            cancelAutomaticReauthentication(accountID: accountID)
        }
    }

    /// Stops the automatic attempt running for this account and gives the
    /// banner its Sign In button back.
    ///
    /// The incident this exists for (2026-09-26): an automatic attempt waited on
    /// a browser window that never reported back, the banner read "Signing you
    /// back in…" with no control at all, and the only hard stop is the
    /// presentation watchdog's 10 minutes.
    ///
    /// Releases the ``AutoReauthPolicy`` claim as UNSUCCESSFUL right here rather
    /// than when the task unwinds, for the same reason as
    /// ``cancelInteractiveSignIn()``: a wedged authentication agent may never
    /// return, and cancellation only helps a presenter that honours it. The
    /// unsuccessful finish starts the cooldown, so Herald does not reopen the
    /// window the user just closed; the user's own Sign In ignores the cooldown
    /// and works at once. The attempt, if it does come back, finds its task no
    /// longer registered and leaves the policy alone (see
    /// ``attemptAutomaticReauthentication(accountID:)``), and a consent that
    /// completes anyway is handled by ``discardAbandonedSignIn(_:)``.
    func cancelAutomaticReauthentication(accountID: Account.ID) {
        guard let attempt = automaticReauthTasks.removeValue(forKey: accountID) else { return }
        logger.info("automatic re-auth cancelled by the user")
        attempt.cancel()
        autoReauth.finish(accountID: accountID, succeeded: false)
    }

    /// Whether a re-auth round trip is running for this account. The banner stays
    /// up and says so, rather than offering a button that would open a second
    /// authorization window over the first.
    func isReauthenticating(accountID: Account.ID) -> Bool {
        autoReauth.isAttempting(accountID: accountID)
    }

    /// Whether the last re-auth attempt for this account was a compose window's
    /// Sign In, which announces its own failure. Read by the re-auth banner when
    /// an attempt ends. Rewritten by EVERY attempt start (user or automatic), so
    /// it can never outlive the attempt it describes.
    func reauthFailureIsAnnouncedByComposer(accountID: Account.ID) -> Bool {
        composerAnnouncedReauths.contains(accountID)
    }

    private func setReauthFailureAnnouncedByComposer(_ announced: Bool, accountID: Account.ID) {
        if announced {
            composerAnnouncedReauths.insert(accountID)
        } else {
            composerAnnouncedReauths.remove(accountID)
        }
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
    /// Scoped to the account the window is SHOWING. A re-auth no longer selects
    /// the account it repairs, but a consent window popping up for an account
    /// the user is not looking at would still be a mystery; the others keep
    /// the banner until ``retryAutomaticReauthentication()`` picks them up —
    /// which is also how a session that died while Herald was in the background
    /// (the common case: the binding expires on a 7-day timer) is repaired the
    /// moment the user comes back.
    ///
    /// Before any consent it PROBES whether the session is still dead
    /// (``healIfSessionRecovered(accountID:)``): another Herald process may
    /// already have signed the account in again, and then the fix is a
    /// re-install, not a window.
    func attemptAutomaticReauthentication(accountID: Account.ID) async {
        guard accountID == selectedAccountID, graphs[accountID]?.mail.status == .needsReauth else { return }
        if await healIfSessionRecovered(accountID: accountID) { return }
        // Re-read after the probe's suspension: the selection, the graph or its
        // status may have moved on meanwhile.
        guard accountID == selectedAccountID, let account = graphs[accountID]?.account,
              graphs[accountID]?.mail.status == .needsReauth
        else { return }
        guard autoReauth.begin(
            accountID: accountID,
            isApplicationActive: isApplicationActive()
        ) else { return }
        setReauthFailureAnnouncedByComposer(false, accountID: accountID)
        reauthErrors[accountID] = nil
        // Held so a sign-out can CANCEL the attempt: its `install` would
        // otherwise land after the account was removed and bring it — and its
        // window selection — straight back.
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.runReauthentication(account: account, generation: nil)
        }
        automaticReauthTasks[accountID] = task
        let succeeded = await task.value
        // Only if this attempt is still the registered one. A Cancel (or a
        // sign-out) has already deregistered it and released the claim, and the
        // account may since have been claimed again — the user clicking Sign In
        // right after Cancel. Finishing here would release THAT claim, bring the
        // Sign In button back under a running consent window, and let a second
        // one open over it.
        guard automaticReauthTasks[accountID] == task else { return }
        automaticReauthTasks[accountID] = nil
        autoReauth.finish(accountID: accountID, succeeded: succeeded)
    }

    /// Re-offers the automatic repair for whatever the window is showing.
    ///
    /// The gates in ``attemptAutomaticReauthentication(accountID:)`` DEFER, they
    /// do not consume: the expiry is announced once, by whatever found it first
    /// (a sync pass, the wake socket, or any request through the token
    /// provider's hook — see ``reportSessionExpired(accountID:)``), and that
    /// usually happens while Herald is in the background or on an account the
    /// window is not showing. Herald becoming frontmost and the user
    /// switching accounts are the two moments a deferred repair becomes possible.
    ///
    /// Also the moment to notice a session that came back WITHOUT Herald: every
    /// other account still on its banner is probed once
    /// (``healIfSessionRecovered(accountID:)`` — a Keychain read, no network, no
    /// window) and re-installed if another process has signed it in again. The
    /// selected account is probed inside its automatic attempt, so each account
    /// is probed at most once per call. The others go FIRST: the selected
    /// account's attempt can wait on a consent window for minutes.
    func retryAutomaticReauthentication() async {
        let selected = selectedAccountID
        for id in accountIDs where id != selected && graphs[id]?.mail.status == .needsReauth {
            await healIfSessionRecovered(accountID: id)
        }
        guard let selected, selectedAccountID == selected else { return }
        await attemptAutomaticReauthentication(accountID: selected)
    }

    /// Re-installs an account stuck on `.needsReauth` whose session is no longer
    /// dead, and returns whether it did — in which case no consent window is
    /// needed.
    ///
    /// Why (audit N2/W10): `.needsReauth` is sticky and the account's engine
    /// stops, so before this only an install cleared it — even when the release
    /// and a dev build share the Keychain and the OTHER one had signed in again,
    /// leaving a healthy grant behind a banner and an automatic consent window.
    ///
    /// "No longer dead" means one thing only: the store holds a DIFFERENT grant
    /// from the one the session died on (``AccountGraph/sessionDeath``,
    /// ``SessionDeath/isCurrent()``) — and not merely the one this graph's own
    /// provider rotated it into by refreshing (HQBase rotates the refresh token
    /// on every use; a bare 401 is never latched and keeps refreshing). The
    /// same session is never "healed" — a bare 401 that keeps coming back
    /// would otherwise turn into a re-install loop — and a store that cannot
    /// be read counts as still dead. What the provider cannot see (another
    /// process refreshing the same dead session) is bounded by
    /// ``AutoReauthPolicy/allowsHeal(accountID:now:)``: one heal per interval. A death the
    /// provider did not detect itself (a bare 401 the sync loop or socket
    /// escalated) has no recorded grant: the first probe records the grant
    /// stored now and heals nothing; a later probe heals only if it changed.
    ///
    /// Cheap by construction: one or two Keychain reads through the provider,
    /// no network until a heal actually re-installs, never a window. Only for
    /// a graph with a real token provider (test graphs on a fake API have
    /// none), never while a sign-in attempt owns the account (its own install
    /// is the fix), and one probe per account at a time.
    @discardableResult
    func healIfSessionRecovered(accountID: Account.ID) async -> Bool {
        // Another probe for the account is running: this call heals nothing
        // itself, and says so — the consent/heal arbitration below
        // (`autoReauth`'s claim, the heal's `isStillWanted`) settles a race.
        guard !healingAccountIDs.contains(accountID) else { return false }
        guard let graph = graphs[accountID], graph.mail.status == .needsReauth,
              let tokens = graph.tokens,
              !autoReauth.isAttempting(accountID: accountID)
        else { return false }
        healingAccountIDs.insert(accountID)
        defer { healingAccountIDs.remove(accountID) }
        guard let death = graph.sessionDeath else {
            let marker = await tokens.deathOfStoredGrant()
            if isCurrent(graph), graph.sessionDeath == nil { graph.sessionDeath = marker }
            return false
        }
        guard await !death.isCurrent() else { return false }
        // Nothing may have claimed the account while the store was read.
        guard isCurrent(graph), graph.mail.status == .needsReauth,
              !autoReauth.isAttempting(accountID: accountID)
        else { return false }
        // At most one heal per interval: two processes sharing a session that
        // stays dead see each other's refreshes as "a different grant".
        guard autoReauth.allowsHeal(accountID: accountID) else {
            logger.info("a different grant is stored, but this account was healed recently; not re-installing again")
            return false
        }
        autoReauth.recordHeal(accountID: accountID)
        logger.info("a different grant is stored for an account on its re-auth banner; re-installing without consent")
        // The stored record, when readable: the process that signed in again may
        // have re-registered (a new client id) or been granted other scopes.
        let stored = (try? await auth.loadAccounts())?.first { $0.id == accountID }
        return await activate(stored ?? graph.account, select: false) { [weak self] in
            // A sign-out, a sign-in's own install or a user attempt started
            // meanwhile each outrank this one.
            guard let self else { return false }
            return self.isCurrent(graph) && graph.mail.status == .needsReauth
                && !self.autoReauth.isAttempting(accountID: accountID)
        }
    }

    /// The re-auth round trip both entry points share. Returns whether the
    /// account is signed in again.
    private func runReauthentication(account: Account, generation: Int?) async -> Bool {
        let isAutomatic = generation == nil
        let accountID = account.id
        let result = await performSignIn(
            originText: account.origin.absoluteString,
            generation: generation,
            isReauthentication: true
        )
        // Said only while this attempt still owns the account: a cancelled one
        // (the user's Cancel moves the generation on and cancels the task; a
        // cancelled automatic one is cancelled too) or one superseded by a
        // newer attempt must not write a stale reason over what is on screen.
        // A closed browser window is `.cancelled`, never a reason.
        if result.outcome == .failed, let reason = result.failureReason, !Task.isCancelled,
           isAutomatic || signInGeneration == generation,
           graphs[accountID] != nil {
            reauthErrors[accountID] = reason
        }
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
        // An INTERACTIVE re-auth for this account would `install` it again right
        // after the sign-out removed it. Only cancelled, like its automatic
        // sibling just below: the whole point of the handle is that its task
        // may never return.
        if signInReauthAccountID == accountID {
            signInGeneration &+= 1
            cancelInteractiveSignIn()
            isSigningIn = false
            signInStage = nil
        }
        // An automatic attempt still running would `install` this account again
        // right after the sign-out removed it. Cancelled, NOT awaited: the
        // attempt may be parked on a wedged authentication agent that never
        // returns, and a sign-out that waited on it would hang with it. Nothing
        // of it can land behind the removal anyway — a cancelled attempt fails
        // `isStillWanted` at every step, and a late consent is handed to
        // `discardAbandonedSignIn`, which finds no graph (`stopGraph` below
        // removes it with no suspension after this cancel) and signs it back out. Deregistered
        // first, so its eventual return leaves the policy alone.
        if let attempt = automaticReauthTasks.removeValue(forKey: accountID) {
            attempt.cancel()
        }
        record(.accountRemoved)
        // Signing back in later must not inherit the dead session's cooldown —
        // nor the reason its last attempt failed.
        autoReauth.forget(accountID: accountID)
        reauthErrors[accountID] = nil
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
            // The onboarding screen, when that is what is showing (the last
            // account went). With accounts left the sheet is closed — its slot
            // would only greet the next Add Account, stale — so the mail
            // window raises an alert instead: an account the Keychain still
            // holds comes back at the next launch, and saying nothing made that
            // look like Herald ignoring the sign-out (P9b, audit N4).
            if graphs.isEmpty {
                signInError = error.localizedDescription
            } else {
                signOutError = Self.signOutFailureMessage(account: account, reason: error.localizedDescription)
            }
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

    /// The mail window's alert text for a sign-out that could not finish.
    /// Pure and static so the wording is assertable without a rendered alert.
    nonisolated static func signOutFailureMessage(account: Account, reason: String) -> String {
        let host = account.origin.host ?? account.origin.absoluteString
        return "Herald closed \(host) but couldn’t remove it from this Mac, "
            + "so it may come back the next time Herald opens. \(reason)"
    }
}
