import Foundation
import HeraldKit
import Testing
@testable import Herald

/// P9b of the 2026-09-26 session-recovery work (round-2 audit items D, E, G, J
/// and nits), app layer.
///
/// - D (N1): an automatic attempt starts the cooldown whatever its outcome, so
///   an escalating 401 without the `invalid_token` challenge cannot reopen the
///   consent window after every successful flash.
/// - E (N2/W10): `.needsReauth` heals WITHOUT consent when the store holds a
///   different grant from the one the session died on (another Herald process
///   signed in again); the same grant still goes to consent.
/// - G: Add Account's activation failure and a sign-out that could not finish
///   are visible.
/// - J: the composer re-saves a draft an overlapping older save left stale, and
///   a second Send during the pre-send waits is refused.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct SessionRecoveryP9bTests {
    static let account = ReauthCancelTests.account
    static let other = ReauthCancelTests.other
    /// Alive for an hour, so nothing in these tests refreshes it by itself: a
    /// refresh would rotate the stored grant and blur "another process signed
    /// in" with "this provider refreshed".
    static let dyingGrant = OAuthTokens(
        accessToken: "dead-access", refreshToken: "dead-refresh", expiresAt: Date().addingTimeInterval(3600)
    )
    static let otherProcessGrant = OAuthTokens(
        accessToken: "other-access", refreshToken: "other-refresh", expiresAt: Date().addingTimeInterval(3600)
    )

    private static func scratchDefaults() -> UserDefaults {
        let suite = "SessionRecoveryP9bTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - E: healing without consent

    struct HealHarness {
        let environment: AppEnvironment
        let keychain: InMemoryAccountStore
        let presenter: ScriptedOutcomePresenter
        let flag: ReauthCancelTests.ActivationFlag
        let graph: AccountGraph
        var accountID: Account.ID { SessionRecoveryP9bTests.account.id }
    }

    /// `account` activated through the REAL `activate` (real provider over
    /// `keychain`, so the graph has a token provider to probe), Herald in the
    /// background. With `selectOther`, a second (fake) account is installed
    /// and selected afterwards, so `account` sits behind the window.
    static func healHarness(selectOther: Bool = false) async throws -> HealHarness {
        let keychain = InMemoryAccountStore(accounts: [account, other])
        try keychain.setTokens(dyingGrant, for: account.id)
        let presenter = ScriptedOutcomePresenter()
        let flag = ReauthCancelTests.ActivationFlag(false)
        let environment = AppEnvironment(
            auth: AuthCoordinator(store: keychain, presenter: presenter, session: OAuthTestServer.session()),
            defaults: scratchDefaults(),
            isApplicationActive: { flag.isActive }
        )
        let mailStore = try MailStore.inMemory()
        environment.store = mailStore
        #expect(await environment.activate(account))
        if selectOther {
            await environment.install(account: other, api: FakeMailAPIClient(), store: mailStore, select: true)
            #expect(environment.selectedAccountID == other.id)
        }
        let graph = try #require(environment.graphs[account.id])
        // The tests drive every attempt themselves.
        graph.mail.reauthenticationRequired = nil
        return HealHarness(environment: environment, keychain: keychain, presenter: presenter, flag: flag, graph: graph)
    }

    /// The provider's own death (post-refresh 401 with `invalid_token`), then
    /// ANOTHER process writes a fresh grant into the shared Keychain item.
    /// Coming to the front must re-install the account on it — no consent
    /// window, banner gone. Fails on the pre-P9b app, which opened consent for
    /// a healthy grant (and without an automatic attempt, never healed).
    @Test func anotherProcessSigningInHealsOnActivationWithoutConsent() async throws {
        let h = try await Self.healHarness()
        let provider = try #require(h.graph.tokens)
        await provider.sessionRejected(token: Self.dyingGrant.accessToken)
        #expect(h.graph.mail.status == .needsReauth)
        #expect(h.graph.sessionDeath != nil, "the provider's death was not kept for a later probe")

        try h.keychain.setTokens(Self.otherProcessGrant, for: h.accountID)
        h.flag.isActive = true
        await h.environment.setWindowActive(true)

        #expect(h.presenter.attemptCount == 0, "a consent window opened for a grant another process had already renewed")
        let healed = try #require(h.environment.graphs[h.accountID])
        #expect(healed !== h.graph, "the account was not re-installed")
        #expect(healed.mail.status != .needsReauth)
        #expect(h.environment.selectedAccountID == h.accountID)
        #expect(h.environment.isReauthenticating(accountID: h.accountID) == false)
        await h.environment.stopGraph(accountID: h.accountID)
    }

    /// The control: the grant the session died on is STILL the stored one —
    /// activation goes to consent exactly as before, and nothing is re-installed.
    @Test func aStillDeadGrantStillGoesToConsent() async throws {
        let h = try await Self.healHarness()
        let provider = try #require(h.graph.tokens)
        await provider.sessionRejected(token: Self.dyingGrant.accessToken)
        h.presenter.script(.fail(.webAuthenticationFailed("no")))

        h.flag.isActive = true
        await h.environment.setWindowActive(true)

        #expect(h.presenter.attemptCount == 1, "a dead grant must still get its consent window")
        #expect(h.environment.graphs[h.accountID] === h.graph, "a dead grant was 'healed' by a re-install")
        #expect(h.graph.mail.status == .needsReauth)
        await h.environment.stopGraph(accountID: h.accountID)
    }

    /// A death the provider did NOT detect: a bare 401 the sync loop escalated
    /// (no challenge, so no latch and no `SessionDeath`). The first probe only
    /// records the grant stored then — it heals nothing — and a later probe
    /// heals once another process has stored a different grant. Fails if the
    /// first probe heals (a re-install per escalation of the same grant: a
    /// loop), or if the recorded marker never lets a renewal heal.
    @Test func aBare401DeathHealsOnlyAfterTheGrantChanges() async throws {
        let h = try await Self.healHarness()
        h.graph.mail.reportSessionExpired()
        #expect(h.graph.sessionDeath == nil)

        // In the background: probes, records, heals nothing, opens nothing.
        await h.environment.retryAutomaticReauthentication()
        #expect(h.graph.sessionDeath != nil, "the first probe did not record the grant")
        #expect(h.environment.graphs[h.accountID] === h.graph, "the same grant was re-installed")

        try h.keychain.setTokens(Self.otherProcessGrant, for: h.accountID)
        h.flag.isActive = true
        await h.environment.setWindowActive(true)

        #expect(h.presenter.attemptCount == 0)
        let healed = try #require(h.environment.graphs[h.accountID])
        #expect(healed !== h.graph)
        #expect(healed.mail.status != .needsReauth)
        await h.environment.stopGraph(accountID: h.accountID)
    }

    /// The audit's own-refresh case: after the bare-401 marker is recorded,
    /// this graph's provider refreshes by itself (a message open, an autosave
    /// through the same provider) — the store now holds a different refresh
    /// token, but it is the SAME dead session. Fails if activation re-installs
    /// it without consent (a re-install per activation, bypassing the
    /// cooldown); it must go to consent as before.
    @Test func theGraphsOwnRefreshAfterTheDeathIsNotAHeal() async throws {
        let h = try await Self.healHarness()
        let provider = try #require(h.graph.tokens)
        h.graph.mail.reportSessionExpired()
        await h.environment.retryAutomaticReauthentication()
        #expect(h.graph.sessionDeath != nil)

        // `OAuthTestServer`'s token endpoint mints hqb_refresh_1.
        _ = try await provider.refreshAccessToken(failedToken: Self.dyingGrant.accessToken)
        #expect(try h.keychain.tokens(for: h.accountID)?.refreshToken != Self.dyingGrant.refreshToken)
        h.presenter.script(.fail(.webAuthenticationFailed("no")))
        h.flag.isActive = true
        await h.environment.setWindowActive(true)

        #expect(h.environment.graphs[h.accountID] === h.graph, "the graph's own refresh was 'healed' by a re-install")
        #expect(h.presenter.attemptCount == 1, "a still-dead session must still get its consent window")
        await h.environment.stopGraph(accountID: h.accountID)
    }

    /// Two processes sharing a session that stays dead see each other's
    /// refreshes as "a different grant". Fails if a second heal within the
    /// interval re-installs again (they would re-install each other on every
    /// activation) instead of falling back to the rate-limited consent path.
    @Test func aSecondHealWithinTheIntervalIsRefused() async throws {
        let h = try await Self.healHarness()
        let provider = try #require(h.graph.tokens)
        await provider.sessionRejected(token: Self.dyingGrant.accessToken)
        try h.keychain.setTokens(Self.otherProcessGrant, for: h.accountID)
        h.flag.isActive = true
        await h.environment.setWindowActive(true)
        let healed = try #require(h.environment.graphs[h.accountID])
        #expect(healed !== h.graph)

        // The healed graph's session dies too, and the OTHER process refreshes.
        healed.mail.reauthenticationRequired = nil
        let healedProvider = try #require(healed.tokens)
        await healedProvider.sessionRejected(token: Self.otherProcessGrant.accessToken)
        #expect(healed.mail.status == .needsReauth)
        try h.keychain.setTokens(Self.dyingGrant, for: h.accountID)
        h.presenter.script(.fail(.webAuthenticationFailed("no")))
        await h.environment.setWindowActive(true)

        #expect(h.environment.graphs[h.accountID] === healed, "a second heal within the interval re-installed again")
        #expect(h.presenter.attemptCount == 1, "the refused heal must fall back to consent")
        await h.environment.stopGraph(accountID: h.accountID)
    }

    /// An account behind the window is probed on activation too (no consent is
    /// ever opened for it — it is not selected), and healed without taking the
    /// window. Fails if only the selected account is probed.
    @Test func aBackgroundAccountHealsOnActivationWithoutTakingTheWindow() async throws {
        let h = try await Self.healHarness(selectOther: true)
        let provider = try #require(h.graph.tokens)
        await provider.sessionRejected(token: Self.dyingGrant.accessToken)
        #expect(h.graph.mail.status == .needsReauth)

        try h.keychain.setTokens(Self.otherProcessGrant, for: h.accountID)
        h.flag.isActive = true
        await h.environment.setWindowActive(true)

        let healed = try #require(h.environment.graphs[h.accountID])
        #expect(healed !== h.graph, "a background account on its banner was not probed")
        #expect(healed.mail.status != .needsReauth)
        #expect(h.environment.selectedAccountID == Self.other.id, "healing took the window")
        #expect(h.presenter.attemptCount == 0)
        await h.environment.stopGraph(accountID: h.accountID)
        await h.environment.stopGraph(accountID: Self.other.id)
    }

    // MARK: - D: no consent loop

    /// N1 end to end: an automatic attempt SUCCEEDS, and the fresh graph's
    /// session is escalated dead again at once (a bare 401 — no latch, so
    /// nothing short of the policy stops it). Fails on the pre-P9b policy: the
    /// success cleared the cooldown and the consent window opened again.
    @Test func aSuccessfulAutomaticAttemptDoesNotReopenConsentOnTheNextEscalation() async throws {
        let h = try await ReauthFailureReasonTests.harness()
        h.flag.isActive = true
        await h.environment.attemptAutomaticReauthentication(accountID: h.accountID)
        #expect(h.presenter.attemptCount == 1)
        let fresh = try #require(h.environment.graphs[h.accountID])
        #expect(fresh !== h.graph, "the automatic attempt did not install")

        fresh.mail.reauthenticationRequired = nil
        fresh.mail.reportSessionExpired()
        await h.environment.attemptAutomaticReauthentication(accountID: h.accountID)
        await h.environment.retryAutomaticReauthentication()

        #expect(h.presenter.attemptCount == 1, "the consent window reopened right after a successful attempt")
        #expect(fresh.mail.status == .needsReauth, "the banner is the fallback and must stay")
        // The user's own Sign In still works at once.
        await h.environment.reauthenticate(accountID: h.accountID)
        #expect(h.presenter.attemptCount == 2)
        await h.environment.stopGraph(accountID: h.accountID)
        await h.environment.stopGraph(accountID: Self.other.id)
    }

    // MARK: - G: failures that were invisible

    /// Add Account whose activation fails while other accounts are up: the
    /// sheet must stay open with the reason on it. Fails on the pre-P9b code,
    /// which closed the sheet before activating — the reason went to a closed
    /// sheet and was wiped when it next opened.
    @Test func addAccountActivationFailureKeepsTheSheetOpenWithTheReason() async throws {
        let keychain = InMemoryAccountStore(accounts: [Self.other])
        let presenter = ScriptedOutcomePresenter()
        let environment = AppEnvironment(
            auth: AuthCoordinator(store: keychain, presenter: presenter, session: OAuthTestServer.session()),
            defaults: Self.scratchDefaults(),
            isApplicationActive: { false }
        )
        await environment.install(account: Self.other, api: FakeMailAPIClient(), store: try MailStore.inMemory())
        // Activation's first requirement is the mail cache; without it the
        // activation fails after consent — the case under test.
        environment.store = nil

        environment.presentsAddAccount = true
        await environment.signIn(originText: Self.account.origin.absoluteString)

        #expect(presenter.attemptCount == 1)
        #expect(environment.graphs[Self.account.id] == nil)
        #expect(environment.presentsAddAccount, "the sheet closed before the account was installed")
        #expect(environment.signInError != nil, "the activation failure was not shown")
        #expect(environment.isSigningIn == false)
        await environment.stopGraph(accountID: Self.other.id)
    }

    /// The control: an installed account closes the sheet.
    @Test func addAccountClosesTheSheetOnceInstalled() async throws {
        let keychain = InMemoryAccountStore(accounts: [Self.other])
        let environment = AppEnvironment(
            auth: AuthCoordinator(store: keychain, presenter: ScriptedOutcomePresenter(), session: OAuthTestServer.session()),
            defaults: Self.scratchDefaults(),
            isApplicationActive: { false }
        )
        await environment.install(account: Self.other, api: FakeMailAPIClient(), store: try MailStore.inMemory())

        environment.presentsAddAccount = true
        await environment.signIn(originText: Self.account.origin.absoluteString)

        #expect(environment.graphs[Self.account.id] != nil)
        #expect(environment.presentsAddAccount == false)
        #expect(environment.signInError == nil)
        await environment.stopGraph(accountID: Self.account.id)
        await environment.stopGraph(accountID: Self.other.id)
    }

    /// Audit N4: sign-out's Keychain half fails while another account remains.
    /// Fails if the failure is only logged (the account comes back at the next
    /// launch with nothing ever having said so) or lands in the onboarding
    /// sheet's slot, where nobody sees it until the next Add Account.
    @Test func aSignOutThatCannotFinishWithAccountsLeftRaisesAnAlert() async throws {
        let environment = AppEnvironment(
            auth: AuthCoordinator(store: UnlistableAccountStore()),
            defaults: Self.scratchDefaults(),
            isApplicationActive: { false }
        )
        let mailStore = try MailStore.inMemory()
        await environment.install(account: Self.other, api: FakeMailAPIClient(), store: mailStore)
        await environment.install(account: Self.account, api: FakeMailAPIClient(), store: mailStore, select: false)

        await environment.signOut(accountID: Self.account.id)

        let message = try #require(environment.signOutError, "a failed sign-out said nothing")
        #expect(message == AppEnvironment.signOutFailureMessage(
            account: Self.account, reason: AccountStoreError.indexUnreadable.localizedDescription
        ))
        #expect(message.contains(Self.account.origin.host!))
        #expect(environment.signInError == nil)

        // The last account going: the onboarding screen says it, not an alert.
        environment.signOutError = nil
        await environment.signOut(accountID: Self.other.id)
        #expect(environment.signOutError == nil)
        #expect(environment.signInError == AccountStoreError.indexUnreadable.localizedDescription)
    }

    // MARK: - Nit: a damaged account list is explained

    /// Fails if a damaged (non-JSON) account list sends the launch to
    /// onboarding without a word. The control: an empty list says nothing.
    @Test func aDamagedAccountListIsExplainedAtLaunch() async throws {
        let damaged = AppEnvironment(
            auth: AuthCoordinator(store: DamagedIndexStore()),
            defaults: Self.scratchDefaults(),
            isApplicationActive: { false }
        )
        damaged.store = try MailStore.inMemory()
        await damaged.restoreAccounts()
        #expect(damaged.phase == .signedOut)
        #expect(damaged.signInError == AppEnvironment.damagedAccountIndexMessage)

        let empty = AppEnvironment(
            auth: AuthCoordinator(store: InMemoryAccountStore()),
            defaults: Self.scratchDefaults(),
            isApplicationActive: { false }
        )
        empty.store = try MailStore.inMemory()
        await empty.restoreAccounts()
        #expect(empty.phase == .signedOut)
        #expect(empty.signInError == nil)
    }

    // MARK: - J: the composer

    private static func composeAPI() async -> FakeMailAPIClient {
        let api = FakeMailAPIClient()
        await api.enableCompose()
        return api
    }

    /// An update in flight on the OLD outbox across a rebind, an edit saved
    /// through the NEW one, and then the older update finishing LAST: the
    /// server now holds the stale text. Fails unless the composer notices it is
    /// still dirty and saves the newer text again.
    @Test(.timeLimit(.minutes(1)))
    func anOlderSaveLandingLastIsFollowedByAResave() async throws {
        let oldAPI = await Self.composeAPI()
        let newAPI = await Self.composeAPI()
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: OutboxService(api: oldAPI),
            autosaveDelay: .zero
        )
        model.subject = "Plans"
        try await wait("the draft to be created") { await oldAPI.createdDrafts.count == 1 && !model.draft.isDirty }

        await oldAPI.holdUpdates()
        model.bodyText = "A"
        try await wait("the update of A to be in flight on the old outbox") { await oldAPI.parkedUpdateCount == 1 }

        model.accountSignedIn(outbox: OutboxService(api: newAPI))
        model.bodyText = "B"
        try await wait("B to be saved through the new outbox") {
            await newAPI.updatedDrafts.last?.text == "B" && !model.draft.isDirty
        }
        let savesBefore = await newAPI.updatedDrafts.count

        await oldAPI.releaseUpdates()
        try await wait("the old update to land last") { await oldAPI.updatedDrafts.count == 1 }
        #expect(await oldAPI.updatedDrafts.first?.text == "A")

        try await wait("B to be saved again over the stale A") {
            await newAPI.updatedDrafts.count == savesBefore + 1
        }
        #expect(await newAPI.updatedDrafts.last?.text == "B")
        try await wait("the draft to settle") { !model.draft.isDirty && !model.hasPendingAutosave }
        await model.waitForAutosave()
        // Settled: nothing keeps re-saving a clean draft.
        try await Task.sleep(for: .milliseconds(30))
        #expect(await newAPI.updatedDrafts.count == savesBefore + 1, "the re-save turned into a loop")
    }

    /// Send pressed twice while the first save is still creating the draft:
    /// both used to park in the create wait BEFORE `.sending` was set, wake
    /// together, and send the message twice. Fails unless the second press is
    /// refused.
    @Test(.timeLimit(.minutes(1)))
    func aSecondSendDuringThePreSendWaitIsRefused() async throws {
        let api = await Self.composeAPI()
        await api.holdCreates()
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: OutboxService(api: api),
            autosaveDelay: .zero
        )
        model.toText = "friend@example.com"
        model.bodyText = "Hello"
        try await wait("the create to be in flight") { await api.parkedCreateCount == 1 }

        let first = Task { await model.send() }
        try await wait("the first send to wait for the create") { model.draftCreationWaiterCount >= 1 }
        let waitersBefore = model.draftCreationWaiterCount
        // Observed through a box, not by awaiting the task: without the guard
        // the second Send parks behind the held create, and awaiting it would
        // hang the test instead of failing it.
        let secondResult = SendResultBox()
        Task { secondResult.value = await model.send() }
        try await wait("the second Send to return at once") { secondResult.value != nil }
        #expect(secondResult.value == false, "a second Send was accepted while the first was waiting")
        #expect(model.draftCreationWaiterCount == waitersBefore)

        await api.releaseCreates()
        #expect(await first.value)
        let sends = await api.sentInputs.count
        #expect(sends == 1, "one message was sent \(sends) times")
    }
}

@MainActor private final class SendResultBox {
    var value: Bool?
}

/// An account store whose list cannot be read — so `AuthCoordinator.signOut`
/// fails (before any network) with the user-readable `indexUnreadable`.
private nonisolated final class UnlistableAccountStore: AccountStore {
    private let backing = InMemoryAccountStore()
    func accounts() throws -> [Account] { throw AccountStoreError.indexUnreadable }
    func add(_ account: Account) throws { throw AccountStoreError.indexUnreadable }
    func remove(_ accountID: Account.ID) throws { throw AccountStoreError.indexUnreadable }
    func tokens(for accountID: Account.ID) throws -> OAuthTokens? { try backing.tokens(for: accountID) }
    func setTokens(_ tokens: OAuthTokens?, for accountID: Account.ID) throws { try backing.setTokens(tokens, for: accountID) }
    func clientID(for origin: URL) throws -> String? { try backing.clientID(for: origin) }
    func setClientID(_ clientID: String, for origin: URL) throws { try backing.setClientID(clientID, for: origin) }
    func forgetClientID(_ clientID: String, for origin: URL) throws -> Bool { try backing.forgetClientID(clientID, for: origin) }
}

/// What `KeychainAccountStore` reports for an index that is not JSON: no
/// accounts, and damaged.
private nonisolated final class DamagedIndexStore: AccountStore {
    private let backing = InMemoryAccountStore()
    func accounts() throws -> [Account] { [] }
    func accountIndexIsDamaged() throws -> Bool { true }
    func add(_ account: Account) throws { try backing.add(account) }
    func remove(_ accountID: Account.ID) throws { try backing.remove(accountID) }
    func tokens(for accountID: Account.ID) throws -> OAuthTokens? { try backing.tokens(for: accountID) }
    func setTokens(_ tokens: OAuthTokens?, for accountID: Account.ID) throws { try backing.setTokens(tokens, for: accountID) }
    func clientID(for origin: URL) throws -> String? { try backing.clientID(for: origin) }
    func setClientID(_ clientID: String, for origin: URL) throws { try backing.setClientID(clientID, for: origin) }
    func forgetClientID(_ clientID: String, for origin: URL) throws -> Bool { try backing.forgetClientID(clientID, for: origin) }
}
