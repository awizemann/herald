import Foundation
import HeraldKit
import Testing
@testable import Herald

/// P3 of the 2026-09-26 session-recovery plan: the re-auth banner and the
/// sidebar are never a dead end.
///
/// The incident: "Your session expired. Signing you back in…" with a spinner and
/// NO control for as long as the automatic attempt waited on a browser window
/// that never reported back — the only hard stop being the 10-minute watchdog.
/// These pin the Cancel that automatic attempts now get, what a consent that
/// lands after it does (and, for the user-initiated Cancel, no longer does), and
/// the two small UI rules around it.
@MainActor
@Suite struct ReauthCancelTests {
    /// Served by `OAuthTestServer`, so a re-auth runs the real `addAccount`
    /// round trip — discovery, registration, the presenter, the code exchange
    /// and the Keychain write — with only the browser window scripted.
    static let account = Account(
        origin: URL(string: "https://\(OAuTestServerConstants.host)")!,
        clientID: "cid_registered",
        scopes: []
    )
    static let other = Account(origin: URL(string: "https://127.0.0.1:9")!, clientID: "cid", scopes: [])
    static let deadGrant = OAuthTokens(accessToken: "dead-access", refreshToken: "dead-refresh")
    /// What `OAuthTestServer`'s token endpoint mints.
    static let freshAccessToken = "hqb_access_1"

    /// One installed, selected account whose session has been reported dead
    /// while Herald was in the background (so nothing has started yet).
    struct Harness {
        let environment: AppEnvironment
        let store: SaveGatedAccountStore
        let presenter: GatedPresenter
        let tracker: RecordingUsageTracker
        let flag: ActivationFlag
        let graph: AccountGraph

        var mail: MailViewModel { graph.mail }
        var accountID: Account.ID { ReauthCancelTests.account.id }

        /// Starts the automatic attempt (Herald comes to the front) and waits for
        /// it to reach the browser hand-off. The returned task is the attempt's
        /// own `attemptAutomaticReauthentication` call.
        func startAutomaticAttempt() async throws -> Task<Void, Never> {
            flag.isActive = true
            let environment = environment
            let accountID = accountID
            let attempt = Task { await environment.attemptAutomaticReauthentication(accountID: accountID) }
            let expected = presenter.attemptCount + 1
            try await wait("the automatic attempt to reach the browser") {
                presenter.attemptCount == expected
            }
            #expect(environment.isReauthenticating(accountID: accountID))
            return attempt
        }

        /// The recorded `account_reauthenticated` outcomes, in order.
        func reauthOutcomes() async -> [UsageValue?] {
            await environment.drainPendingUsage()
            return await tracker.events.filter { $0.name == "account_reauthenticated" }.map { $0.props["outcome"] }
        }
    }

    final class ActivationFlag: @unchecked Sendable {
        var isActive: Bool
        init(_ isActive: Bool) { self.isActive = isActive }
    }

    static func harness(api: FakeMailAPIClient = FakeMailAPIClient(), also: [Account] = []) async throws -> Harness {
        let store = SaveGatedAccountStore(accounts: [account] + also)
        try store.setTokens(deadGrant, for: account.id)
        let presenter = GatedPresenter()
        let tracker = RecordingUsageTracker()
        let flag = ActivationFlag(false)
        let suite = "ReauthCancelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let environment = AppEnvironment(
            auth: AuthCoordinator(store: store, presenter: presenter, session: OAuthTestServer.session()),
            defaults: defaults,
            usage: tracker,
            isApplicationActive: { flag.isActive }
        )
        let mailStore = try MailStore.inMemory()
        await environment.install(account: account, api: api, store: mailStore)
        for extra in also {
            await environment.install(account: extra, api: FakeMailAPIClient(), store: mailStore, select: false)
        }
        let graph = try #require(environment.graphs[account.id])
        #expect(environment.selectedAccountID == account.id)
        // The tests start the automatic attempt themselves, so they hold its
        // task. The transition's own hook would start one in an unstructured
        // `Task` that runs later — after a test has brought Herald to the front
        // — and win the claim.
        graph.mail.reauthenticationRequired = nil
        graph.mail.reportSessionExpired()
        #expect(graph.mail.status == .needsReauth)
        #expect(environment.isReauthenticating(accountID: account.id) == false)
        return Harness(
            environment: environment, store: store, presenter: presenter,
            tracker: tracker, flag: flag, graph: graph
        )
    }

    // MARK: - Cancel on an automatic attempt

    /// The incident, with a browser hand-off that NEVER returns (the attempt's
    /// task is never released here). Fails if the claim waits for the task —
    /// the banner would keep its spinner and no Sign In for as long as the agent
    /// is wedged — or if it is released as a success (no cooldown: Herald would
    /// reopen the window the user just closed on the next activation).
    @Test func cancellingAnAutomaticAttemptReleasesTheClaimAtOnceWithACooldown() async throws {
        let h = try await Self.harness()
        h.presenter.ignoresCancellation(ofAttempt: 1)
        let attempt = try await h.startAutomaticAttempt()

        h.environment.cancelReauthentication(accountID: h.accountID)

        #expect(h.environment.isReauthenticating(accountID: h.accountID) == false, "the Sign In button did not come back")
        #expect(h.environment.automaticReauthTasks[h.accountID] == nil)
        #expect(
            h.environment.autoReauth.allowsAttempt(accountID: h.accountID, isApplicationActive: true) == false,
            "a cancelled attempt must start the cooldown"
        )
        // And the cooldown is what the entry point obeys: coming back to the
        // front does not reopen the window.
        await h.environment.retryAutomaticReauthentication()
        #expect(h.presenter.attemptCount == 1, "Herald reopened the window the user just cancelled")
        #expect(h.mail.status == .needsReauth, "the banner must stay up after a cancel")

        h.presenter.releaseAll()
        await attempt.value
    }

    /// A presenter that honours cancellation (`WebAuthenticationRunner` does:
    /// its cancellation handler cancels the `ASWebAuthenticationSession`) is
    /// actually torn down by the Cancel — the attempt's task returns, as a
    /// cancel, and installs nothing. Fails if the Cancel only flips UI state and
    /// leaves the browser session running.
    @Test func cancelTearsDownACancellablePresenter() async throws {
        let h = try await Self.harness()
        let attempt = try await h.startAutomaticAttempt()

        h.environment.cancelReauthentication(accountID: h.accountID)
        await attempt.value

        #expect(h.presenter.cancelledAttempts == [1], "the browser session was not cancelled")
        #expect(h.environment.graphs[h.accountID] === h.graph)
        #expect(await h.reauthOutcomes() == [.string("cancelled")])
        #expect(try h.store.tokens(for: h.accountID) == Self.deadGrant, "nothing was consented to, so nothing is written")
    }

    // MARK: - A consent that lands after the Cancel

    /// The Cancel lands while the consent is already past the point of no
    /// return — the code exchanged, the Keychain write in progress (a slow
    /// `securityd`, reproduced by gating the write). Cancellation cannot stop a
    /// write already running, so `addAccount` returns having stored the new
    /// grant. The decision pinned here: for an account that is ALREADY signed
    /// in, that grant is KEPT and the account is brought back on it — a fresh
    /// graph, its composers rebound — WITHOUT taking the window.
    ///
    /// Fails on the pre-P3 undo (`auth.signOut`), which removed the account and
    /// its tokens from the Keychain — the Cancel of a repair would have deleted
    /// the user's account at the next launch. Fails on P3's keep-but-install-
    /// nothing (D3): the account worked but the banner and the composer's Sign
    /// In still said it was dead, and once the cooldown ran out Herald flashed
    /// a consent window for it (the last block). Fails too if the re-install
    /// pulls the window back to the account the user had moved away from (W8).
    @Test func aLateConsentAfterCancellingAnAutomaticAttemptKeepsTheAccountAndBringsItBackUnselected() async throws {
        let api = FakeMailAPIClient()
        await api.enableCompose()
        await api.setComposeError(.unauthorized)
        let h = try await Self.harness(api: api, also: [Self.other])
        let environment = h.environment
        let accountID = h.accountID
        let composeID = try #require(await environment.prepareCompose(ComposeRequest(kind: .new)))
        let composer = try #require(environment.makeComposeViewModel(id: composeID))
        composer.toText = "friend@example.com"
        composer.bodyText = "Hello"
        #expect(await composer.send() == false)
        #expect(composer.signInAffordance == .available)

        h.presenter.releaseAll()
        h.store.armSaveGate()
        h.flag.isActive = true
        let attempt = Task { await environment.attemptAutomaticReauthentication(accountID: accountID) }
        try await wait("the consent to reach the Keychain write") { h.store.isBlocked }
        // The user moves to another account while it runs, then cancels.
        environment.selectAccount(Self.other.id)
        environment.cancelReauthentication(accountID: accountID)
        #expect(environment.isReauthenticating(accountID: accountID) == false)

        h.store.openSaveGate()
        await attempt.value

        #expect(await h.reauthOutcomes() == [.string("cancelled")])
        #expect(try h.store.accounts().map(\.id).contains(accountID), "the cancel signed the existing account out")
        #expect(try h.store.tokens(for: accountID)?.accessToken == Self.freshAccessToken)
        #expect(environment.isReauthenticating(accountID: accountID) == false)
        let revived = try #require(environment.graphs[accountID])
        #expect(revived !== h.graph, "the kept grant was not brought back: the UI still says the session is dead")
        #expect(revived.mail.status != .needsReauth, "the banner outlived the kept grant")
        #expect(composer.signInAffordance == .none, "the composer's Sign In outlived the kept grant")
        #expect(environment.makeComposeViewModel(id: composeID) === composer)
        #expect(environment.selectedAccountID == Self.other.id, "a cancelled consent took the window")

        // Past the cooldown, back on the account: nothing to repair, so no
        // consent window flashes for a healthy account.
        environment.autoReauth = AutoReauthPolicy()
        environment.selectAccount(accountID)
        await environment.attemptAutomaticReauthentication(accountID: accountID)
        #expect(h.presenter.attemptCount == 1, "Herald re-ran consent for an account that is signed in")
        await environment.stopGraph(accountID: accountID)
    }

    /// The SAME trap on the path that existed before P3: the user's own Sign In,
    /// cancelled, then the consent completing anyway. Fails on the old
    /// stale-generation undo, which signed the existing account out, and on
    /// P3's leave-it-dead (D3).
    @Test func aLateConsentAfterCancellingTheUsersOwnReauthDoesNotSignTheAccountOut() async throws {
        let h = try await Self.harness()
        h.presenter.releaseAll()
        h.store.armSaveGate()
        let environment = h.environment
        let accountID = h.accountID
        let attempt = Task { await environment.reauthenticate(accountID: accountID) }
        try await wait("the consent to reach the Keychain write") { h.store.isBlocked }
        #expect(environment.isSigningIn && environment.signInReauthAccountID == accountID, "the user's attempt must own the sign-in")

        environment.cancelReauthentication(accountID: accountID)
        #expect(environment.isSigningIn == false)
        #expect(environment.isReauthenticating(accountID: accountID) == false)

        h.store.openSaveGate()
        await attempt.value

        #expect(await h.reauthOutcomes() == [.string("cancelled")])
        #expect(try h.store.accounts().map(\.id).contains(accountID), "the cancel signed the existing account out")
        #expect(try h.store.tokens(for: accountID)?.accessToken == Self.freshAccessToken)
        #expect(environment.isSigningIn == false)
        let revived = try #require(environment.graphs[accountID])
        #expect(revived !== h.graph)
        #expect(revived.mail.status != .needsReauth)
        #expect(environment.selectedAccountID == accountID)
        await environment.stopGraph(accountID: accountID)
    }

    // MARK: - Re-auth never takes the window (W8)

    /// The user's own Sign In for an account the window is NOT showing (the
    /// sidebar's button, or a compose window's): it succeeds and installs a
    /// new graph, and the window stays on the account the user is reading.
    /// Fails if a re-auth selects the account it repaired.
    @Test func aReauthOfABackgroundAccountLeavesTheSelectionAlone() async throws {
        let h = try await Self.harness(also: [Self.other])
        let environment = h.environment
        environment.selectAccount(Self.other.id)
        h.presenter.releaseAll()

        await environment.reauthenticate(accountID: h.accountID)

        #expect(environment.graphs[h.accountID] !== h.graph, "the sign-in did not install")
        #expect(environment.graphs[h.accountID]?.mail.status != .needsReauth)
        #expect(environment.selectedAccountID == Self.other.id, "the re-auth took the window")
        await environment.stopGraph(accountID: h.accountID)
    }

    // MARK: - Sign-out never waits on a wedged attempt (W9)

    /// An automatic attempt parked on an authentication agent that never
    /// answers — and ignores cancellation. Fails if sign-out awaits it (it
    /// would hang with it). And once the agent does wake and completes the
    /// consent, the late consent is signed back out: no graph, no account in
    /// the Keychain.
    @Test(.timeLimit(.minutes(1)))
    func signOutDoesNotWaitForAWedgedAutomaticAttempt() async throws {
        let h = try await Self.harness(also: [Self.other])
        h.presenter.ignoresCancellation(ofAttempt: 1)
        let attempt = try await h.startAutomaticAttempt()
        let environment = h.environment
        let accountID = h.accountID

        let signOut = Task { await environment.signOut(accountID: accountID) }
        try await wait("the sign-out to finish while the attempt is still wedged") {
            environment.graphs[accountID] == nil && environment.accountIDs == [Self.other.id]
                && (try? h.store.accounts().map(\.id).contains(accountID)) == false
        }
        await signOut.value
        #expect(environment.isReauthenticating(accountID: accountID) == false)
        #expect(environment.selectedAccountID == Self.other.id)

        // The agent wakes and the consent completes after all.
        h.presenter.release(1)
        await attempt.value
        #expect(environment.graphs[accountID] == nil, "a late consent brought a signed-out account back")
        #expect(try h.store.accounts().map(\.id).contains(accountID) == false, "a late consent left the account in the Keychain")
        #expect(environment.selectedAccountID == Self.other.id)
    }

    /// The other half of the rule: an account that is NOT signed in here (an
    /// Add Account the user cancelled) is still undone — kept, it would be a
    /// deferred sign-in the next launch restores. Fails if the new
    /// keep-the-grant branch swallows it.
    @Test func aLateConsentForANewAccountIsStillUndone() async throws {
        let store = SaveGatedAccountStore()
        let presenter = GatedPresenter()
        presenter.releaseAll()
        let environment = SignInRecoveryTests.environment(presenter: presenter, store: store)
        store.armSaveGate()
        let attempt = Task { await environment.signIn(originText: SignInRecoveryTests.origin) }
        try await wait("the consent to reach the Keychain write") { store.isBlocked }

        environment.cancelSignIn()
        store.openSaveGate()
        await attempt.value

        #expect(environment.graphs.isEmpty)
        #expect(try store.accounts().isEmpty, "a cancelled Add Account was left in the Keychain")
    }

    // MARK: - Sign In right after Cancel

    /// Cancel, then Sign In at once: the user's attempt runs immediately (it
    /// ignores the cooldown the Cancel just started), and the stale automatic
    /// attempt coming back afterwards must not touch it. Fails if the stale
    /// attempt's completion `finish`es the policy over the user's claim — the
    /// banner would drop the user's Cancel and offer Sign In again under a
    /// running consent window, and a click would open a second one.
    @Test func signInRightAfterCancelRunsAndTheStaleAttemptDoesNotClobberIt() async throws {
        let h = try await Self.harness()
        h.presenter.ignoresCancellation(ofAttempt: 1)
        let automatic = try await h.startAutomaticAttempt()
        let environment = h.environment
        let accountID = h.accountID

        environment.cancelReauthentication(accountID: accountID)
        let user = Task { await environment.reauthenticate(accountID: accountID) }
        try await wait("the user's attempt to reach the browser") { h.presenter.attemptCount == 2 }
        #expect(environment.isReauthenticating(accountID: accountID))

        // The stale automatic attempt comes back.
        h.presenter.release(1)
        await automatic.value
        #expect(environment.isReauthenticating(accountID: accountID), "the stale attempt released the user's claim")
        #expect(environment.isSigningIn && environment.signInReauthAccountID == accountID, "the user's attempt must own the sign-in")
        #expect(environment.graphs[accountID] === h.graph, "the stale attempt installed the account")

        // The user's own attempt completes normally.
        h.presenter.release(2)
        await user.value
        #expect(environment.isReauthenticating(accountID: accountID) == false)
        #expect(environment.graphs[accountID] !== h.graph, "the user's sign-in did not install")
        #expect(environment.graphs[accountID]?.mail.status != .needsReauth)
        #expect(
            environment.autoReauth.allowsAttempt(accountID: accountID, isApplicationActive: true),
            "a successful sign-in clears the cooldown the Cancel started"
        )
    }

    // MARK: - The sidebar

    /// The red "Sign in again" is a button exactly when the banner would offer
    /// Sign In, and a DISABLED one while an attempt runs (a second click would
    /// be refused by the policy). Fails if the button leaks into the other
    /// states or stays enabled over a running attempt.
    @Test func theSidebarOffersSignInOnlyForAnExpiredSession() {
        typealias Label = SyncStatusLabel
        #expect(Label.signInAffordance(for: .needsReauth, isReauthenticating: false) == .available)
        #expect(Label.signInAffordance(for: .needsReauth, isReauthenticating: true) == .inProgress)
        for status: MailViewModel.SyncStatus in [.idle, .syncing, .failed("x")] {
            #expect(Label.signInAffordance(for: status, isReauthenticating: false) == .none)
            #expect(Label.signInAffordance(for: status, isReauthenticating: true) == .none)
        }
    }

    /// The banner's "Sign-in cancelled" is for the account whose Cancel the user
    /// pressed. The banner view's state survives an account switch, so a flag
    /// left over from account A must not turn B's attempt ending into a cancel.
    @Test func theBannersCancelAnnouncementIsKeyedToTheAccount() {
        typealias Banner = ReauthBanner
        let a = Self.account.id
        let b = Self.other.id
        #expect(Banner.stateChangeAnnouncement(isReauthenticating: false, cancelledAccountID: a, accountID: a)
            == Banner.cancelledAnnouncement)
        #expect(Banner.stateChangeAnnouncement(isReauthenticating: false, cancelledAccountID: a, accountID: b)
            == Banner.announcement(isReauthenticating: false), "A's cancel leaked into B's banner")
        #expect(Banner.stateChangeAnnouncement(isReauthenticating: false, cancelledAccountID: nil, accountID: a)
            == Banner.announcement(isReauthenticating: false))
        #expect(Banner.stateChangeAnnouncement(isReauthenticating: true, cancelledAccountID: a, accountID: a)
            == Banner.announcement(isReauthenticating: true))
    }

    /// What the sidebar's button calls, while an automatic attempt holds the
    /// account: nothing new starts (no second window) — which is why the
    /// control is drawn disabled rather than left looking clickable.
    @Test func theSidebarsActionDuringAnAttemptOpensNoSecondWindow() async throws {
        let h = try await Self.harness()
        h.presenter.ignoresCancellation(ofAttempt: 1)
        let automatic = try await h.startAutomaticAttempt()

        await h.environment.reauthenticate(accountID: h.accountID)
        #expect(h.presenter.attemptCount == 1, "a second consent window opened over the first")

        h.presenter.releaseAll()
        await automatic.value
    }

    // MARK: - A blip does not hide the banner

    /// A NON-auth failure (server error, transport blip) on a pass after the
    /// session was reported dead. Fails if it overwrites `.needsReauth` with
    /// "Sync problem / Retry", which hid the only way back in.
    @Test func aNonAuthFailureAfterExpiryKeepsTheSignInBanner() async throws {
        let api = FakeMailAPIClient()
        let h = try await Self.harness(api: api)
        await api.setListError(.server(code: "INTERNAL", message: "boom"))

        await h.mail.refresh()
        try await wait("the failing pass") {
            await h.environment.drainPendingUsage()
            return await h.tracker.names.contains("sync_failed")
        }

        #expect(h.mail.status == .needsReauth, "a blip replaced the sign-in banner")
    }
}

// MARK: - Presenter

/// Each `authorize` call is one numbered attempt that pends until released.
/// By default an attempt honours cancellation (throwing `.userCancelled`, the
/// way `WebAuthenticationRunner` does); one marked with
/// ``ignoresCancellation(ofAttempt:)`` is the wedged authentication agent,
/// which hears nothing until it wakes and completes the consent anyway.
nonisolated final class GatedPresenter: AuthorizationPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private var released: Set<Int> = []
    private var deaf: Set<Int> = []
    private var cancelled: [Int] = []
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releasesEverything = false

    var attemptCount: Int { lock.withLock { attempts } }
    var cancelledAttempts: [Int] { lock.withLock { cancelled } }

    func ignoresCancellation(ofAttempt attempt: Int) { lock.withLock { _ = deaf.insert(attempt) } }

    func release(_ attempt: Int) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released.insert(attempt)
            return waiting.removeValue(forKey: attempt)
        }
        continuation?.resume()
    }

    /// Releases every attempt, current and future — test cleanup.
    func releaseAll() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            releasesEverything = true
            defer { waiting.removeAll() }
            return Array(waiting.values)
        }
        continuations.forEach { $0.resume() }
    }

    private func isReleased(_ attempt: Int) -> Bool {
        lock.withLock { releasesEverything || released.contains(attempt) }
    }

    func authorize(url: URL, callbackScheme: String) async throws -> URL {
        let (attempt, isDeaf) = lock.withLock { () -> (Int, Bool) in
            attempts += 1
            return (attempts, deaf.contains(attempts))
        }
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value ?? ""
        let callback = URL(string: "com.wizemann.herald:/oauth/callback?code=auth_code_1&state=\(state)")!

        if isDeaf {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if releasesEverything || released.contains(attempt) { return true }
                    waiting[attempt] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
            return callback
        }
        while !isReleased(attempt) {
            do {
                try await Task.sleep(for: .milliseconds(2))
            } catch {
                lock.withLock { cancelled.append(attempt) }
                throw OAuthError.userCancelled
            }
        }
        return callback
    }
}

// MARK: - Store

/// An in-memory account store whose account write can be made to block (a
/// slow `securityd`), so a cancel can land AFTER the consent and the code
/// exchange but before `addAccount` returns — the one window in which a
/// cancelled sign-in still writes its grant.
nonisolated final class SaveGatedAccountStore: AccountStore, @unchecked Sendable {
    private let backing: InMemoryAccountStore
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed = false
    private var blocked = false

    init(accounts: [Account] = []) { backing = InMemoryAccountStore(accounts: accounts) }

    var isBlocked: Bool { lock.withLock { blocked } }

    /// The NEXT `add(_:)` blocks until ``openSaveGate()``.
    func armSaveGate() { lock.withLock { armed = true } }
    func openSaveGate() { gate.signal() }

    func add(_ account: Account) throws {
        let shouldBlock = lock.withLock { () -> Bool in
            guard armed else { return false }
            armed = false
            blocked = true
            return true
        }
        if shouldBlock {
            gate.wait()
            lock.withLock { blocked = false }
        }
        try backing.add(account)
    }

    func accounts() throws -> [Account] { try backing.accounts() }
    func remove(_ accountID: Account.ID) throws { try backing.remove(accountID) }
    func tokens(for accountID: Account.ID) throws -> OAuthTokens? { try backing.tokens(for: accountID) }
    func setTokens(_ tokens: OAuthTokens?, for accountID: Account.ID) throws {
        try backing.setTokens(tokens, for: accountID)
    }
    func clientID(for origin: URL) throws -> String? { try backing.clientID(for: origin) }
    func setClientID(_ clientID: String, for origin: URL) throws { try backing.setClientID(clientID, for: origin) }
    func forgetClientID(_ clientID: String, for origin: URL) throws -> Bool { try backing.forgetClientID(clientID, for: origin) }
}
