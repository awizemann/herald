import Foundation
import HeraldKit
import Testing
@testable import Herald

/// Audit W5: a failed re-auth says why, where the user is looking.
///
/// Before: the reason went to `signInError`, which only the onboarding sheet
/// shows. A failed Sign In from the banner, the sidebar or a compose window
/// just flipped back to "Sign In" with no explanation, and the stale message
/// then greeted the user in the next Add Account.
@MainActor
@Suite struct ReauthFailureReasonTests {
    static let account = ReauthCancelTests.account
    static let other = ReauthCancelTests.other
    static let reason = "The sign-in window never appeared."

    struct Harness {
        let environment: AppEnvironment
        let presenter: ScriptedOutcomePresenter
        let flag: ReauthCancelTests.ActivationFlag
        let graph: AccountGraph
        var accountID: Account.ID { ReauthFailureReasonTests.account.id }
    }

    /// Two installed accounts; `account` is selected and its session was
    /// reported dead while Herald was in the background.
    static func harness(api: FakeMailAPIClient = FakeMailAPIClient()) async throws -> Harness {
        let store = SaveGatedAccountStore(accounts: [account, other])
        try store.setTokens(ReauthCancelTests.deadGrant, for: account.id)
        let presenter = ScriptedOutcomePresenter()
        let flag = ReauthCancelTests.ActivationFlag(false)
        let suite = "ReauthFailureReasonTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let environment = AppEnvironment(
            auth: AuthCoordinator(store: store, presenter: presenter, session: OAuthTestServer.session()),
            defaults: defaults,
            isApplicationActive: { flag.isActive }
        )
        let mailStore = try MailStore.inMemory()
        await environment.install(account: account, api: api, store: mailStore)
        await environment.install(account: other, api: FakeMailAPIClient(), store: mailStore, select: false)
        let graph = try #require(environment.graphs[account.id])
        // The tests start any automatic attempt themselves.
        graph.mail.reauthenticationRequired = nil
        graph.mail.reportSessionExpired()
        #expect(graph.mail.status == .needsReauth)
        return Harness(environment: environment, presenter: presenter, flag: flag, graph: graph)
    }

    // MARK: - Set, scoped, and kept off the onboarding sheet

    /// Fails on the pre-fix code: the reason lands in `signInError` (the
    /// onboarding sheet) and nothing per-account exists. Also fails if the
    /// reason leaks to another account, or if opening Add Account afterwards
    /// shows it.
    @Test func aFailedUserReauthShowsItsReasonForThatAccountOnly() async throws {
        let h = try await Self.harness()
        h.presenter.script(.fail(.webAuthenticationFailed(Self.reason)))

        await h.environment.reauthenticate(accountID: h.accountID)

        #expect(h.environment.reauthError(accountID: h.accountID) == Self.reason)
        #expect(h.environment.reauthError(accountID: Self.other.id) == nil, "another account got the reason")
        #expect(h.environment.signInError == nil, "a re-auth wrote the onboarding sheet's error")
        #expect(h.environment.isReauthenticating(accountID: h.accountID) == false)
        #expect(h.graph.mail.status == .needsReauth, "the banner must stay up after a failure")

        h.environment.presentsAddAccount = true
        #expect(h.environment.signInError == nil, "Add Account opened on a re-auth's message")
        await h.environment.stopGraph(accountID: h.accountID)
    }

    /// Herald's own attempt reports its reason too (the banner is already up;
    /// see `AppEnvironment.reauthErrors` for why that is not noise).
    @Test func aFailedAutomaticAttemptShowsItsReason() async throws {
        let h = try await Self.harness()
        h.presenter.script(.fail(.webAuthenticationFailed(Self.reason)))
        h.flag.isActive = true

        await h.environment.attemptAutomaticReauthentication(accountID: h.accountID)

        #expect(h.presenter.attemptCount == 1)
        #expect(h.environment.reauthError(accountID: h.accountID) == Self.reason)
        #expect(h.environment.signInError == nil)
        await h.environment.stopGraph(accountID: h.accountID)
    }

    /// Closing the browser window is a choice, not a failure: no reason.
    @Test func closingTheBrowserWindowRecordsNoReason() async throws {
        let h = try await Self.harness()
        h.presenter.script(.fail(.userCancelled))

        await h.environment.reauthenticate(accountID: h.accountID)

        #expect(h.presenter.attemptCount == 1)
        #expect(h.environment.reauthError(accountID: h.accountID) == nil)
        await h.environment.stopGraph(accountID: h.accountID)
    }

    // MARK: - Cleared

    /// Fails if a new attempt keeps showing the old reason under "Signing you
    /// back in…", or if a Cancel leaves one behind (a cancel is not an error —
    /// and the cancelled attempt's own unwinding must not write one either).
    @Test func theReasonClearsWhenAnAttemptStartsAndStaysClearAfterCancel() async throws {
        let h = try await Self.harness()
        h.presenter.script(.fail(.webAuthenticationFailed(Self.reason)))
        await h.environment.reauthenticate(accountID: h.accountID)
        #expect(h.environment.reauthError(accountID: h.accountID) == Self.reason)

        h.presenter.script(.pendUntilCancelledThenFail(.webAuthenticationFailed("late failure")))
        let environment = h.environment
        let accountID = h.accountID
        let retry = Task { await environment.reauthenticate(accountID: accountID) }
        try await wait("the retry to reach the browser") { h.presenter.attemptCount == 2 }
        #expect(h.environment.reauthError(accountID: h.accountID) == nil, "the old reason outlived the new attempt's start")

        h.environment.cancelReauthentication(accountID: h.accountID)
        await retry.value

        #expect(h.environment.reauthError(accountID: h.accountID) == nil, "a cancelled attempt recorded a reason")
        #expect(h.environment.signInError == nil)
        await h.environment.stopGraph(accountID: h.accountID)
    }

    /// Same for an automatic attempt cancelled from the banner.
    @Test func aCancelledAutomaticAttemptRecordsNoReason() async throws {
        let h = try await Self.harness()
        // An earlier failure's reason. Set directly: a real failed attempt would
        // start the cooldown and keep the automatic attempt from running.
        h.environment.reauthErrors[h.accountID] = Self.reason

        h.presenter.script(.pendUntilCancelledThenFail(.webAuthenticationFailed("late failure")))
        h.flag.isActive = true
        let environment = h.environment
        let accountID = h.accountID
        let attempt = Task { await environment.attemptAutomaticReauthentication(accountID: accountID) }
        try await wait("the automatic attempt to reach the browser") { h.presenter.attemptCount == 1 }
        #expect(h.environment.reauthError(accountID: h.accountID) == nil)

        h.environment.cancelReauthentication(accountID: h.accountID)
        await attempt.value

        #expect(h.environment.reauthError(accountID: h.accountID) == nil, "a cancelled automatic attempt recorded a reason")
        await h.environment.stopGraph(accountID: h.accountID)
    }

    /// A later success clears it (the install does), and the banner goes.
    @Test func aSuccessfulSignInClearsTheReason() async throws {
        let h = try await Self.harness()
        h.presenter.script(.fail(.webAuthenticationFailed(Self.reason)))
        await h.environment.reauthenticate(accountID: h.accountID)
        #expect(h.environment.reauthError(accountID: h.accountID) == Self.reason)

        h.presenter.script(.succeed)
        await h.environment.reauthenticate(accountID: h.accountID)

        #expect(h.environment.graphs[h.accountID] !== h.graph, "the sign-in did not install a new graph")
        #expect(h.environment.reauthError(accountID: h.accountID) == nil)
        await h.environment.stopGraph(accountID: h.accountID)
    }

    /// Any (re)install of the account clears it — whichever path got there.
    @Test func installingTheAccountClearsTheReason() async throws {
        let h = try await Self.harness()
        h.environment.reauthErrors[h.accountID] = Self.reason
        h.environment.reauthErrors[Self.other.id] = "other"

        await h.environment.install(account: Self.account, api: FakeMailAPIClient(), store: try MailStore.inMemory(), select: false)

        #expect(h.environment.reauthError(accountID: h.accountID) == nil)
        #expect(h.environment.reauthError(accountID: Self.other.id) == "other", "another account's reason was cleared")
        await h.environment.stopGraph(accountID: h.accountID)
    }

    /// Signing the account out forgets it — a later sign-in of the same origin
    /// must not inherit it.
    @Test func signingOutClearsTheReason() async throws {
        let h = try await Self.harness()
        h.presenter.script(.fail(.webAuthenticationFailed(Self.reason)))
        await h.environment.reauthenticate(accountID: h.accountID)
        #expect(h.environment.reauthError(accountID: h.accountID) == Self.reason)

        await h.environment.signOut(accountID: h.accountID)

        #expect(h.environment.reauthErrors.isEmpty)
        #expect(h.environment.signInError == nil)
    }

    /// A fresh Add Account sheet starts clean, whatever failed before it was
    /// last closed — but a sign-in running in it keeps its own message slot.
    @Test func openingAddAccountClearsAStaleOnboardingMessage() async throws {
        let h = try await Self.harness()
        h.environment.signInError = "stale"
        h.environment.presentsAddAccount = true
        #expect(h.environment.signInError == nil)

        h.environment.presentsAddAccount = false
        h.environment.signInError = "current"
        h.environment.isSigningIn = true
        h.environment.presentsAddAccount = true
        #expect(h.environment.signInError == "current")

        // P9b: a user's RE-AUTH also raises `isSigningIn`, but never writes
        // this slot — what is there is stale and must not greet the sheet.
        h.environment.presentsAddAccount = false
        h.environment.signInReauthAccountID = h.accountID
        h.environment.presentsAddAccount = true
        #expect(h.environment.signInError == nil, "a re-auth kept a stale Add Account failure on the sheet")
        h.environment.signInReauthAccountID = nil
        h.environment.isSigningIn = false
        await h.environment.stopGraph(accountID: h.accountID)
    }

    // MARK: - Where it shows

    /// The banner's and VoiceOver's wording.
    @Test func theBannerCarriesTheReasonAndAnnouncesIt() throws {
        let a = Self.account.id
        #expect(ReauthBanner.failureDetail(Self.reason).hasSuffix(Self.reason))
        let failed = try #require(ReauthBanner.stateChangeAnnouncement(
            isReauthenticating: false, cancelledAccountID: nil, accountID: a, failureReason: Self.reason
        ))
        #expect(failed.contains(Self.reason))
        #expect(failed.contains("Sign In button"))
        // A cancel is announced as a cancel even if an older reason exists.
        #expect(ReauthBanner.stateChangeAnnouncement(
            isReauthenticating: false, cancelledAccountID: a, accountID: a, failureReason: Self.reason
        ) == ReauthBanner.cancelledAnnouncement)
        // Starting an attempt never announces a failure.
        #expect(ReauthBanner.stateChangeAnnouncement(
            isReauthenticating: true, cancelledAccountID: nil, accountID: a, failureReason: Self.reason
        ) == ReauthBanner.announcement(isReauthenticating: true))
    }

    /// The compose window's error bar: the composer's OWN account's reason,
    /// shown only while Sign In is offered, and announced when the window's
    /// own Sign In fails.
    @Test func theComposersSignInShowsItsAccountsReason() async throws {
        let api = FakeMailAPIClient()
        await api.enableCompose()
        await api.setComposeError(.unauthorized)
        let h = try await Self.harness(api: api)
        let environment = h.environment
        let id = try #require(await environment.prepareCompose(ComposeRequest(kind: .new)))
        let model = try #require(environment.makeComposeViewModel(id: id))
        model.toText = "friend@example.com"
        model.bodyText = "Hello"
        // No dead-session failure on the bar yet: no Sign In, so no reason
        // either, even though the account has one.
        environment.reauthErrors[h.accountID] = "earlier"
        #expect(model.signInAffordance == .none)
        #expect(model.signInFailureReason == nil, "a reason showed without a Sign In to go with it")
        environment.reauthErrors[h.accountID] = nil
        #expect(await model.send() == false)
        #expect(model.signInAffordance == .available)
        #expect(model.signInFailureReason == nil)

        h.presenter.script(.fail(.webAuthenticationFailed(Self.reason)))
        await model.signIn()

        #expect(model.signInAffordance == .available)
        #expect(model.signInFailureReason == ComposeViewModel.signInFailureDetail(Self.reason))
        #expect(model.announcement?.contains(Self.reason) == true, "the composer's failed Sign In was silent")
        // P9b nit: the composer announced it, so the banner (which may show the
        // same account) stays quiet — one failure, heard once.
        #expect(environment.reauthFailureIsAnnouncedByComposer(accountID: h.accountID))
        #expect(ReauthBanner.stateChangeAnnouncement(
            isReauthenticating: false, cancelledAccountID: nil, accountID: h.accountID,
            failureReason: environment.reauthError(accountID: h.accountID),
            failureAnnouncedElsewhere: environment.reauthFailureIsAnnouncedByComposer(accountID: h.accountID)
        ) == nil, "VoiceOver hears the composer's failed Sign In twice")
        // The banner's own Sign In owns its failure again.
        h.presenter.script(.fail(.webAuthenticationFailed(Self.reason)))
        await environment.reauthenticate(accountID: h.accountID)
        #expect(environment.reauthFailureIsAnnouncedByComposer(accountID: h.accountID) == false)
        #expect(ReauthBanner.stateChangeAnnouncement(
            isReauthenticating: false, cancelledAccountID: nil, accountID: h.accountID,
            failureReason: environment.reauthError(accountID: h.accountID),
            failureAnnouncedElsewhere: environment.reauthFailureIsAnnouncedByComposer(accountID: h.accountID)
        ) == ReauthBanner.failureAnnouncement(Self.reason))

        // Another account's failure is not this composer's business.
        environment.reauthErrors = [Self.other.id: "other"]
        #expect(model.signInFailureReason == nil)
        await environment.stopGraph(accountID: h.accountID)
    }
}

/// Answers each authorization with the next scripted outcome (default: a
/// valid callback).
nonisolated final class ScriptedOutcomePresenter: AuthorizationPresenter, @unchecked Sendable {
    enum Outcome: Sendable {
        case succeed
        case fail(OAuthError)
        /// Pends until the attempt's task is cancelled, then throws — a failure
        /// that arrives only because the attempt was abandoned.
        case pendUntilCancelledThenFail(OAuthError)
    }

    private let lock = NSLock()
    private var queue: [Outcome] = []
    private var attempts = 0

    var attemptCount: Int { lock.withLock { attempts } }

    func script(_ outcome: Outcome) { lock.withLock { queue.append(outcome) } }

    func authorize(url: URL, callbackScheme: String) async throws -> URL {
        let outcome = lock.withLock { () -> Outcome in
            attempts += 1
            return queue.isEmpty ? .succeed : queue.removeFirst()
        }
        switch outcome {
        case .succeed:
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "state" }?.value ?? ""
            return URL(string: "com.wizemann.herald:/oauth/callback?code=auth_code_1&state=\(state)")!
        case .fail(let error):
            throw error
        case .pendUntilCancelledThenFail(let error):
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2))
            }
            throw error
        }
    }
}
