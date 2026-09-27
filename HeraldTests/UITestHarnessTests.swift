import Foundation
import HeraldKit
import SwiftData
import Testing
@testable import Herald

/// The Debug-only UI-test launch mode (plan `documents/plans/ui-tests-2026-09-27.md`, U1).
///
/// Three promises are tested here, because U2+ UI tests stand on them:
/// 1. the mode is INERT unless `-HeraldUITest <scenario>` is passed, and a
///    malformed request is refused rather than silently falling back to the real
///    Keychain and network;
/// 2. with it, EVERY dependency is a fake;
/// 3. each fake-server state produces the documented wire behaviour through the
///    REAL `HQBaseAPIClient` + `AccountTokenProvider`, and each presenter mode
///    behaves like the real sign-in window (cancellation included).
@MainActor
@Suite struct UITestLaunchArgumentTests {
    @Test func noArgumentMeansNoTestMode() throws {
        #expect(try UITestLaunchConfiguration.parse(arguments: ["/Applications/Herald.app/Contents/MacOS/Herald"]) == nil)
        // The server/presenter flags alone do not switch the mode on.
        #expect(try UITestLaunchConfiguration.parse(arguments: ["Herald", "-HeraldUITestServer", "healthy"]) == nil)
        #expect(UITestLaunchConfiguration.isRequested(in: ["Herald", "-NSDocumentRevisionsDebugMode", "YES"]) == false)
    }

    @Test func fullContractParses() throws {
        let configuration = try #require(try UITestLaunchConfiguration.parse(arguments: [
            "Herald", "-HeraldUITest", "twoAccounts",
            "-HeraldUITestServer", "deadSession140",
            "-HeraldUITestPresenter", "fail:No network",
        ]))
        #expect(configuration.scenario == .twoAccounts)
        #expect(configuration.serverState == .deadSession140)
        #expect(configuration.presenterMode == .fail("No network"))

        let defaults = try #require(try UITestLaunchConfiguration.parse(arguments: ["Herald", "-HeraldUITest", "signedOut"]))
        #expect(defaults.serverState == .healthy)
        #expect(defaults.presenterMode == .succeed)
    }

    /// Fails if a malformed request falls through to the REAL composition root
    /// (returns nil) — a UI test would then drive the real Keychain and network.
    @Test(arguments: [
        ["Herald", "-HeraldUITest"],
        ["Herald", "-HeraldUITest", "-HeraldUITestServer", "healthy"],
        ["Herald", "-HeraldUITest", "bogus"],
        ["Herald", "-HeraldUITest", "oneAccount", "-HeraldUITestServer", "dead"],
        ["Herald", "-HeraldUITest", "oneAccount", "-HeraldUITestServer"],
        ["Herald", "-HeraldUITest", "oneAccount", "-HeraldUITestPresenter", "maybe"],
    ])
    func malformedRequestsAreRefused(arguments: [String]) {
        #expect(throws: UITestLaunchConfiguration.ParseError.self) {
            _ = try UITestLaunchConfiguration.parse(arguments: arguments)
        }
    }

    @Test func presenterModeArguments() {
        #expect(SignInPresenterMode(argument: "succeed") == .succeed)
        #expect(SignInPresenterMode(argument: "hangUntilCancelled") == .hangUntilCancelled)
        #expect(SignInPresenterMode(argument: "userCancel") == .userCancel)
        #expect(SignInPresenterMode(argument: "fail") == .fail(SignInPresenterMode.defaultFailureReason))
        #expect(SignInPresenterMode(argument: "fail:Server down") == .fail("Server down"))
        #expect(SignInPresenterMode(argument: "hang") == nil)
    }

    /// The test host itself is launched WITHOUT the argument: the real
    /// composition path must be the one chosen. Fails if the harness is picked
    /// up without being asked for.
    @Test func theRealCompositionRootIsChosenWithoutTheArgument() {
        #expect(UITestHarness.launched == nil)
        let environment = HeraldApp.makeEnvironment()
        #expect(environment.apiSession === URLSession.shared)
        #expect(environment.routesNotificationClicks)
    }

    /// Sparkle and analytics stand down on the REQUEST alone, before any harness
    /// exists. Fails if either only checks for a test host.
    @Test func sparkleAndAnalyticsStandDownInTestMode() {
        let args = ["Herald", "-HeraldUITest", "oneAccount"]
        #expect(UpdateService.startsUpdater(arguments: args, isRunningUnderTests: false, isDebugBuild: false) == false)
        #expect(UpdateService.startsUpdater(arguments: ["Herald"], isRunningUnderTests: false, isDebugBuild: false))

        let validKey = "whk_0123456789abcdef"
        let testMode = UsageAnalytics.makeTracker(environment: [:], arguments: args, writeKey: validKey)
        #expect(testMode.isAvailable == false, "analytics ran in UI-test mode")
        // Control: the same key without the flag builds the real tracker.
        let normal = UsageAnalytics.makeTracker(environment: [:], arguments: ["Herald"], writeKey: validKey)
        #expect(normal.isAvailable)
    }
}

@MainActor
@Suite(.scratchDefaults) struct UITestHarnessWiringTests {
    static func harness(
        _ scenario: UITestLaunchConfiguration.Scenario,
        server: FakeHQBaseState = .healthy,
        presenter: SignInPresenterMode = .succeed
    ) -> (UITestHarness, String) {
        let suite = ScratchDefaults.suiteName()
        let harness = UITestHarness(
            configuration: UITestLaunchConfiguration(scenario: scenario, serverState: server, presenterMode: presenter),
            defaultsSuiteName: suite
        )
        return (harness, suite)
    }

    static func cleanUp(_ harness: UITestHarness, suite: String) async {
        for id in harness.environment.accountIDs { await harness.environment.stopGraph(accountID: id) }
        ScratchDefaults.discard(suite)
    }

    /// Fails if any real dependency survives into test mode.
    @Test func everyDependencyIsFake() async throws {
        let (harness, suite) = Self.harness(.oneAccount)
        defer { ScratchDefaults.discard(suite) }
        let environment = harness.environment

        #expect(environment.apiSession !== URLSession.shared)
        let classes = environment.apiSession.configuration.protocolClasses ?? []
        #expect(classes.count == 1 && classes.first == FakeHQBaseProtocol.self,
                "the REST session could reach something other than the fake server")
        #expect(environment.routesNotificationClicks == false)
        #expect(environment.usage is NoopUsageTracker)
        #expect(environment.defaults !== UserDefaults.standard)

        let container = try environment.makeMailContainer()
        let inMemory = container.configurations.allSatisfy { $0.isStoredInMemoryOnly }
        #expect(inMemory, "the mail cache is on disk")

        let channels = environment.makeEventChannels(UITestOrigins.primary)
        #expect(channels is FakeEventChannels)
        await #expect(throws: MailEventChannelError.rejected(status: 503)) {
            _ = try await channels.open(token: "anything")
        }
        #expect(harness.network.all.first?.counters.eventRefusals == 1)
    }

    /// Fails if the defaults suite is shared across launches (a UI test would
    /// inherit the previous run's selection, mailbox colours, settings).
    @Test func theDefaultsSuiteIsWipedAtLaunch() {
        let suite = ScratchDefaults.suiteName()
        defer { ScratchDefaults.discard(suite) }
        let first = UITestHarness(configuration: .init(scenario: .signedOut), defaultsSuiteName: suite)
        first.defaults.set("leftover", forKey: "probe")
        let second = UITestHarness(configuration: .init(scenario: .signedOut), defaultsSuiteName: suite)
        #expect(second.defaults.string(forKey: "probe") == nil)
    }

    @Test func seedsMatchTheirScenario() throws {
        let (signedOut, s1) = Self.harness(.signedOut)
        let (one, s2) = Self.harness(.oneAccount)
        let (two, s3) = Self.harness(.twoAccounts)
        defer { for s in [s1, s2, s3] { ScratchDefaults.discard(s) } }

        #expect(try signedOut.accountStore.accounts().isEmpty)
        #expect(try one.accountStore.accounts().map(\.origin) == [UITestOrigins.primary])
        let origins = try two.accountStore.accounts().map(\.origin)
        #expect(Set(origins) == [UITestOrigins.primary, UITestOrigins.secondary], "two accounts must be on two origins")
        for account in try two.accountStore.accounts() {
            #expect(try two.accountStore.tokens(for: account.id)?.refreshToken != nil)
        }
    }

    /// The whole launch path end to end: store → restore → activate → sync.
    /// Fails if any request escaped the fake (an `.invalid` host cannot
    /// resolve) or if a wire shape does not decode — the Inbox would stay empty.
    @Test func oneAccountLaunchesIntoASyncedInbox() async throws {
        let (harness, suite) = Self.harness(.oneAccount)
        let environment = harness.environment
        await environment.start()
        #expect(environment.phase == .ready)
        let mail = try #require(environment.mail)
        try await wait("the seeded inbox to sync", timeout: .seconds(10)) {
            mail.allConversations.count == 5
        }
        #expect(mail.allConversations.contains { $0.latest.subject == "Quarterly numbers" })
        #expect(harness.counters.unauthorized == 0)
        await Self.cleanUp(harness, suite: suite)
    }

    /// A full first sign-in: discovery, registration, the scripted window, the
    /// code exchange with PKCE, the Keychain write — all in process. Fails if
    /// the coordinator used a real session (DNS failure), the real presenter
    /// (no window to answer), or the real Keychain (the in-memory store empty).
    @Test func signInRunsEntirelyAgainstTheFakes() async throws {
        let (harness, suite) = Self.harness(.signedOut)
        let environment = harness.environment
        await environment.start()
        #expect(environment.phase == .signedOut)

        await environment.signIn(originText: UITestOrigins.primary.absoluteString)

        #expect(environment.signInError == nil)
        #expect(environment.graphs.count == 1)
        #expect(try harness.accountStore.accounts().count == 1)
        let counters = harness.network.all[0].counters
        #expect(counters.registrations == 1)
        #expect(counters.codeExchanges == 1)
        #expect(harness.presenter.attemptCount == 1)
        await Self.cleanUp(harness, suite: suite)
    }

    /// The status line is the contract U2+ read; fails if its keys change order.
    @Test func statusLineContract() async throws {
        let (harness, suite) = Self.harness(.oneAccount)
        defer { ScratchDefaults.discard(suite) }
        harness.setServerState(.invalidGrant)
        harness.setPresenterMode(.hangUntilCancelled)
        let keys = harness.status.split(separator: " ").map { String($0.split(separator: "=")[0]) }
        #expect(keys == [
            "server", "presenter", "sends", "sendRequests", "tokenRequests", "refreshes", "codeExchanges",
            "registrations", "signIns", "pendingSignIns", "draftCreates", "draftUpdates", "draftDeletes",
            "unauthorized", "revocations", "storeRefusesList", "activationRefused",
            "apiSuccesses", "pollPaused", "heldReads", "saveAttempts",
        ])
        #expect(harness.status.hasPrefix("server=invalidGrant presenter=hangUntilCancelled sends=0 "))
        #expect(harness.status.hasSuffix(" activationRefused=false apiSuccesses=0 pollPaused=false heldReads=0 saveAttempts=0"))
    }

    /// `uitest.poll.pause|resume`: while paused, a Mail API read is held
    /// UNANSWERED and unseen (no counter moves), while a write still goes
    /// through; resuming answers it. Fails if the pause leaks into writes (a
    /// Send could never reach the dead session) or answers reads at once (the
    /// poll could still discover the death).
    @Test(.timeLimit(.minutes(1)))
    func pausingTheSyncPollHoldsReadsOnly() async throws {
        let (harness, suite) = Self.harness(.oneAccount)
        defer { ScratchDefaults.discard(suite) }
        let account = try #require(try harness.accountStore.accounts().first)
        let provider = try await harness.environment.auth.tokenProvider(for: account)
        let api = HQBaseAPIClient(origin: account.origin, tokens: provider, session: harness.session, includeLabels: true)
        let server = harness.network.all[0]

        harness.setSyncPollPaused(true)
        #expect(harness.status.contains(" pollPaused=true "))
        let read = Task { try await api.listMailboxes() }
        try await wait("the read to be held", timeout: .seconds(10)) { server.heldReads == 1 }
        #expect(server.counters.apiSuccesses == 0, "a held read was already answered")
        #expect(server.counters.unauthorized == 0)

        let draft = try await api.createDraft(DraftInput(from: server.mailboxAddress, subject: "while paused"))
        #expect(!draft.id.isEmpty)
        #expect(server.counters.apiSuccesses == 1, "a write was held with the reads")

        harness.setSyncPollPaused(false)
        let mailboxes = try await read.value
        #expect(mailboxes.count == 1)
        #expect(server.counters.apiSuccesses == 2)
        #expect(server.heldReads == 0)
        #expect(harness.status.contains(" pollPaused=false heldReads=0 "))
    }

    /// `saveAttempts=`: counts what the environment's compose hook reports,
    /// and resets with the other counters.
    @Test func saveAttemptsFollowTheComposeHook() throws {
        let (harness, suite) = Self.harness(.oneAccount)
        defer { ScratchDefaults.discard(suite) }
        let hook = try #require(harness.environment.composeSaveAttempted)
        hook()
        hook()
        #expect(harness.status.hasSuffix(" saveAttempts=2"))
        harness.resetCounters()
        #expect(harness.status.hasSuffix(" saveAttempts=0"))
    }

    /// U4 scenario 6 signs in to the SECOND origin from `oneAccount`. Fails if
    /// that origin is not served (the scripted window cannot mint a callback
    /// for it and the sign-in fails before activation) or if serving it
    /// seeded an account there (Add Account would be refused instead).
    @Test func oneAccountServesAnUnseededSecondOrigin() async throws {
        let (harness, suite) = Self.harness(.oneAccount)
        let environment = harness.environment
        await environment.start()
        #expect(try harness.accountStore.accounts().map(\.origin) == [UITestOrigins.primary])

        await environment.signIn(originText: UITestOrigins.secondary.absoluteString)

        #expect(environment.signInError == nil)
        #expect(environment.graphs.count == 2)
        let second = try #require(harness.network.server(for: UITestOrigins.secondary))
        #expect(second.counters.codeExchanges == 1)
        await Self.cleanUp(harness, suite: suite)
    }

    /// `uitest.activation.refuse`: consent completes but activation fails, the
    /// Add Account sheet stays up with the reason, and `healthy` restores the
    /// SAME cache. Fails if the control does not reach activation (the account
    /// installs, the sheet closes) or if the restore loses or replaces the cache.
    @Test func activationRefusalFailsAddAccountAndRestores() async throws {
        let (harness, suite) = Self.harness(.oneAccount)
        let environment = harness.environment
        await environment.start()
        let cache = try #require(environment.store)

        harness.setActivationRefused(true)
        #expect(harness.status.contains(" activationRefused=true "))
        environment.presentsAddAccount = true
        await environment.signIn(originText: UITestOrigins.secondary.absoluteString)

        #expect(harness.presenter.attemptCount == 1, "the failure must come AFTER consent")
        #expect(environment.graphs.count == 1)
        #expect(environment.presentsAddAccount, "the sheet closed on an activation failure")
        #expect(environment.signInError == OAuthError.unknownAccount("").localizedDescription)
        // The running account kept syncing throughout.
        #expect(environment.graphs[environment.accountIDs[0]] != nil)

        harness.setActivationRefused(false)
        #expect(environment.store === cache)
        #expect(harness.status.contains(" activationRefused=false "))
        await Self.cleanUp(harness, suite: suite)
    }
}

/// Each server state through the REAL client stack.
@MainActor
@Suite(.scratchDefaults) struct FakeHQBaseWireTests {
    private nonisolated final class DeathRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var deaths: Int { lock.withLock { count } }
        func record() { lock.withLock { count += 1 } }
    }

    private struct Rig {
        let harness: UITestHarness
        let suite: String
        let account: Account
        let provider: AccountTokenProvider
        let api: HQBaseAPIClient
        let deaths: DeathRecorder
        var server: FakeHQBase { harness.network.all[0] }
    }

    private static func rig(_ state: FakeHQBaseState) async throws -> Rig {
        let (harness, suite) = UITestHarnessWiringTests.harness(.oneAccount)
        let account = try #require(try harness.accountStore.accounts().first)
        let provider = try await harness.environment.auth.tokenProvider(for: account)
        let deaths = DeathRecorder()
        await provider.setSessionRejectedHandler { _ in deaths.record() }
        let api = HQBaseAPIClient(origin: account.origin, tokens: provider, session: harness.session, includeLabels: true)
        // Healthy first: the seeded grant works.
        _ = try await api.listMailboxes()
        harness.setServerState(state)
        harness.resetCounters()
        return Rig(harness: harness, suite: suite, account: account, provider: provider, api: api, deaths: deaths)
    }

    private static func finish(_ rig: Rig) {
        ScratchDefaults.discard(rig.suite)
    }

    /// Raw HTTP, so the documented matrix is asserted on the wire itself:
    /// 1.4.0 dead session = old token 401 invalid_token, refresh 200, new token 401.
    @Test func deadSession140WireMatrix() async throws {
        let (harness, suite) = UITestHarnessWiringTests.harness(.oneAccount, server: .deadSession140)
        defer { ScratchDefaults.discard(suite) }
        let account = try #require(try harness.accountStore.accounts().first)
        let tokens = try #require(try harness.accountStore.tokens(for: account.id))
        let origin = UITestOrigins.primary.absoluteString

        func get(_ token: String) async throws -> HTTPURLResponse {
            var request = URLRequest(url: URL(string: "\(origin)/api/v1/mailboxes")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await harness.session.data(for: request)
            return try #require(response as? HTTPURLResponse)
        }
        let old = try await get(tokens.accessToken)
        #expect(old.statusCode == 401)
        let challenge = try #require(old.value(forHTTPHeaderField: "WWW-Authenticate"))
        #expect(challenge.contains(#"error="invalid_token""#))
        #expect(challenge.hasPrefix("Bearer resource_metadata="))

        var refresh = URLRequest(url: URL(string: "\(origin)/api/auth/oauth2/token")!)
        refresh.httpMethod = "POST"
        refresh.httpBody = Data("grant_type=refresh_token&refresh_token=\(tokens.refreshToken!)&client_id=\(account.clientID)".utf8)
        let (body, response) = try await harness.session.data(for: refresh)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let minted = try #require(FakeHQBase.jsonObject(body)?["access_token"] as? String)
        #expect(minted != tokens.accessToken)
        #expect(try await get(minted).statusCode == 401, "a dead 1.4.0 session must reject the tokens it mints")
    }

    /// Fails if the provider does not latch: a second call would refresh again
    /// (the six-refreshes-in-65-seconds incident).
    @Test func deadSession140LatchesAndAnnouncesOnce() async throws {
        let rig = try await Self.rig(.deadSession140)
        defer { Self.finish(rig) }
        await #expect(throws: (any Error).self) { _ = try await rig.api.listMailboxes() }
        #expect(rig.server.counters.refreshes == 1)
        #expect(rig.deaths.deaths == 1)
        await #expect(throws: (any Error).self) { _ = try await rig.api.listMailboxes() }
        #expect(rig.server.counters.refreshes == 1, "a latched grant refreshed again")
        #expect(rig.deaths.deaths == 1)
        // Latched, not cleared: the tokens stay in the (fake) Keychain.
        #expect(try rig.harness.accountStore.tokens(for: rig.account.id) != nil)
    }

    @Test func invalidGrantClearsTheGrantAndAnnounces() async throws {
        let rig = try await Self.rig(.invalidGrant)
        defer { Self.finish(rig) }
        await #expect(throws: (any Error).self) { _ = try await rig.api.listMailboxes() }
        #expect(rig.server.counters.refreshes == 1)
        #expect(rig.deaths.deaths == 1)
        #expect(try rig.harness.accountStore.tokens(for: rig.account.id) == nil)
    }

    /// A bare token-endpoint 401 is a proxy's, not HQBase's verdict: retryable,
    /// never a latch or a cleared grant.
    @Test func bareTokenEndpoint401IsNotTerminal() async throws {
        let rig = try await Self.rig(.bareTokenEndpoint401)
        defer { Self.finish(rig) }
        await #expect(throws: (any Error).self) { _ = try await rig.api.listMailboxes() }
        #expect(rig.server.counters.refreshes >= 1)
        #expect(rig.deaths.deaths == 0)
        #expect(try rig.harness.accountStore.tokens(for: rig.account.id) != nil)
        #expect(try rig.harness.accountStore.clientID(for: rig.account.origin) != nil)
    }

    /// `invalid_client`: terminal refusal — announced, registration forgotten,
    /// tokens kept.
    @Test func invalidClientForgetsTheRegistration() async throws {
        let rig = try await Self.rig(.invalidClient)
        defer { Self.finish(rig) }
        await #expect(throws: (any Error).self) { _ = try await rig.api.listMailboxes() }
        #expect(rig.deaths.deaths == 1)
        #expect(try rig.harness.accountStore.clientID(for: rig.account.origin) == nil)
        #expect(try rig.harness.accountStore.tokens(for: rig.account.id) != nil)
    }

    /// A Send refused by a dead session is still a send REQUEST (the first
    /// try and the post-refresh retry) and never a send. Fails if the counter
    /// only counts authenticated requests — U3's "exactly once" checks read it.
    @Test func aRefusedSendIsCountedAsRequestsButNotSent() async throws {
        let rig = try await Self.rig(.deadSession140)
        defer { Self.finish(rig) }
        let input = SendInput(from: rig.server.mailboxAddress, to: ["a@example.net"], subject: "s", text: "t")
        await #expect(throws: (any Error).self) { _ = try await rig.api.send(input) }
        #expect(rig.server.counters.sends == 0)
        #expect(rig.server.counters.sendRequests == 2)
    }

    /// Control for the four above: healthy calls never refresh or announce.
    @Test func healthyNeverRefreshes() async throws {
        let rig = try await Self.rig(.healthy)
        defer { Self.finish(rig) }
        _ = try await rig.api.listMailboxes()
        #expect(rig.server.counters.tokenRequests == 0)
        #expect(rig.deaths.deaths == 0)
    }

    /// Recovery path: after any death, a fresh sign-in mints a LIVE grant.
    /// No wait for the dead state first: the sign-in may land while the dead
    /// session's refresh is still in flight (the refresh's late write used to
    /// overwrite the new grant — see `raceARefreshAgainstTheSignIn`).
    @Test(.timeLimit(.minutes(1)))
    func aFreshSignInRecoversFromADeadSession() async throws {
        let (harness, suite) = UITestHarnessWiringTests.harness(.oneAccount, server: .deadSession140)
        let environment = harness.environment
        await environment.start()
        let account = try #require(environment.accounts.first)
        await environment.reauthenticate(accountID: account.id)
        let mail = try #require(environment.mail)
        try await wait("the re-installed account to sync", timeout: .seconds(10)) {
            mail.allConversations.count == 5
        }
        #expect(mail.status != .needsReauth)
        #expect(harness.network.all[0].counters.codeExchanges == 1)
        await UITestHarnessWiringTests.cleanUp(harness, suite: suite)
    }

    /// The U1 repro, held deterministic: the launch's sync is refreshing the
    /// dead 1.4.0 grant (the server has rotated it; the response is held) when
    /// the user signs in again. The sign-in writes its live grant, then the
    /// re-install stops the old graph — which waits for that refresh — so the
    /// refresh's write lands AFTER the sign-in's. Fails if the refresh
    /// persists unconditionally: the store goes back to the dead family and
    /// the new graph re-latches (no sync, or a second consent).
    @Test(.timeLimit(.minutes(1)))
    func aSignInDuringAnInFlightDeadRefreshStaysHealthy() async throws {
        let (harness, suite) = UITestHarnessWiringTests.harness(.oneAccount, server: .deadSession140)
        let environment = harness.environment
        let server = harness.network.all[0]
        server.holdRefreshResponses()
        await environment.start()
        let account = try #require(environment.accounts.first)
        let deadRefreshToken = try #require(try harness.accountStore.tokens(for: account.id)?.refreshToken)
        try await wait("the dead session's refresh to be in flight", timeout: .seconds(10)) {
            server.heldRefreshResponses == 1
        }

        let reauth = Task { await environment.reauthenticate(accountID: account.id) }
        try await wait("the sign-in to write its grant", timeout: .seconds(10)) {
            let stored = try? harness.accountStore.tokens(for: account.id)
            return stored?.refreshToken != deadRefreshToken && server.counters.codeExchanges == 1
        }
        let signedIn = try #require(try harness.accountStore.tokens(for: account.id))
        server.releaseRefreshResponses()
        await reauth.value

        let mail = try #require(environment.mail)
        try await wait("the re-installed account to sync", timeout: .seconds(10)) {
            mail.allConversations.count == 5
        }
        #expect(try harness.accountStore.tokens(for: account.id) == signedIn, "the in-flight refresh overwrote the new grant")
        #expect(mail.status != .needsReauth)
        #expect(server.counters.codeExchanges == 1)
        #expect(server.counters.refreshes == 1, "the new grant was refreshed: it had been replaced by dead tokens")
        await UITestHarnessWiringTests.cleanUp(harness, suite: suite)
    }

    // MARK: Fidelity (U6b / audit F6) — raw wire, one server, a movable clock

    private nonisolated final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { current } }
        func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
    }

    private static func fidelityServer(clock: Clock) -> (FakeHQBase, OAuthTokens, String) {
        let server = FakeHQBase(origin: UITestOrigins.primary, mailboxAddress: "me@hqbase.uitest.invalid", now: { clock.now })
        let clientID = "fidelity-client"
        return (server, server.seedGrant(clientID: clientID), clientID)
    }

    private static func refresh(
        _ server: FakeHQBase, _ refreshToken: String, clientID: String, resource: String? = Account.resource(for: UITestOrigins.primary)
    ) -> (status: Int, body: [String: Any]) {
        var form = "grant_type=refresh_token&refresh_token=\(refreshToken)&client_id=\(clientID)"
        if let resource {
            form += "&resource=\(resource.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? resource)"
        }
        let response = server.respond(to: FakeHTTPRequest(
            method: "POST", path: "/api/auth/oauth2/token", query: [:], headers: [:], body: Data(form.utf8)
        ))
        return (response.status, FakeHQBase.jsonObject(response.body) ?? [:])
    }

    private static func mailboxes(_ server: FakeHQBase, _ accessToken: String) -> FakeHTTPResponse {
        server.respond(to: FakeHTTPRequest(
            method: "GET", path: "/api/v1/mailboxes", query: [:], headers: ["Authorization": "Bearer \(accessToken)"], body: Data()
        ))
    }

    /// Contract: tokens are AUDIENCE-BOUND to the resource the token request
    /// named. Fails if a refresh without `resource` (or with another one)
    /// mints a token the Mail API accepts — Herald dropping the parameter
    /// would then pass every UI test and fail on the real server.
    @Test func aRefreshWithoutTheResourceMintsATokenTheMailAPIRejects() throws {
        let clock = Clock()
        let (server, seeded, clientID) = Self.fidelityServer(clock: clock)

        let bare = Self.refresh(server, try #require(seeded.refreshToken), clientID: clientID, resource: nil)
        #expect(bare.status == 200)
        let unbound = try #require(bare.body["access_token"] as? String)
        #expect(Self.mailboxes(server, unbound).status == 401)

        let wrong = Self.refresh(server, try #require(bare.body["refresh_token"] as? String), clientID: clientID,
                                 resource: "https://hqbase.uitest.invalid/mcp")
        #expect(wrong.status == 200)
        #expect(Self.mailboxes(server, try #require(wrong.body["access_token"] as? String)).status == 401)

        let bound = Self.refresh(server, try #require(wrong.body["refresh_token"] as? String), clientID: clientID)
        #expect(bound.status == 200)
        #expect(Self.mailboxes(server, try #require(bound.body["access_token"] as? String)).status == 200)
    }

    /// Contract #rotation / #invalid-grant: a rotated refresh token replayed
    /// inside `refreshTokenReuseInterval` gets the rotation's own answer (no
    /// new token); after it, the whole family is invalidated — the replayed
    /// token AND the grant's current one answer `invalid_grant`, and no server
    /// state revives it. Fails if the fake answers every replay with
    /// `invalid_grant` (Herald's two-process arbitration would be tested
    /// against a stricter server than production) or never invalidates.
    @Test func aRotatedRefreshTokenGetsTheReplayWindowThenKillsTheFamily() throws {
        let clock = Clock()
        let (server, seeded, clientID) = Self.fidelityServer(clock: clock)
        let original = try #require(seeded.refreshToken)

        let rotation = Self.refresh(server, original, clientID: clientID)
        #expect(rotation.status == 200)
        let current = try #require(rotation.body["refresh_token"] as? String)
        #expect(current != original)

        clock.advance(FakeHQBase.refreshTokenReuseInterval - 1)
        let replay = Self.refresh(server, original, clientID: clientID)
        #expect(replay.status == 200)
        #expect(replay.body["access_token"] as? String == rotation.body["access_token"] as? String, "a replay minted a new token")
        #expect(replay.body["refresh_token"] as? String == current)
        #expect(server.counters.refreshReplays == 1)

        clock.advance(2)
        let late = Self.refresh(server, original, clientID: clientID)
        #expect(late.status == 400)
        #expect(late.body["error"] as? String == "invalid_grant")
        #expect(server.counters.familyInvalidations == 1)
        #expect(Self.refresh(server, current, clientID: clientID).body["error"] as? String == "invalid_grant",
                "the family's live refresh token survived the invalidation")
        server.setState(.healthy)
        #expect(Self.refresh(server, current, clientID: clientID).status == 400, "healthy revived an invalidated family")
    }

    /// Contract (2026-09-26): HQBase's rejection body is the BARE
    /// `{"error":"INVALID_OAUTH_TOKEN"}`, not the Mail API envelope, with the
    /// `invalid_token` challenge. Fails if the fake sends the envelope — a
    /// client that needed `error.code` would pass here and break live.
    @Test func aRejectedTokenGetsTheBare401Body() throws {
        let clock = Clock()
        let (server, _, _) = Self.fidelityServer(clock: clock)
        let response = Self.mailboxes(server, "not-a-token")
        #expect(response.status == 401)
        #expect(FakeHQBase.jsonObject(response.body)?["error"] as? String == "INVALID_OAUTH_TOKEN")
        #expect(response.headers["WWW-Authenticate"]?.contains(#"error="invalid_token""#) == true)
    }

    /// Send idempotency, drafts and signatures through the real client.
    @Test func mailAPIContract() async throws {
        let rig = try await Self.rig(.healthy)
        defer { Self.finish(rig) }
        let from = rig.server.mailboxAddress

        let draft = try await rig.api.createDraft(DraftInput(from: from, to: ["a@example.net"], subject: "Hi", text: "Body"))
        let updated = try await rig.api.updateDraft(id: draft.id, with: DraftInput(
            from: from, to: ["a@example.net"], subject: "Hi again", text: "Body", version: draft.version
        ))
        #expect(updated.version == draft.version + 1)
        // A stale version is a 409 conflict, as on HQBase.
        await #expect(throws: MailAPIError.server(code: "DRAFT_CONFLICT", message: "The draft changed since it was loaded")) {
            _ = try await rig.api.updateDraft(id: draft.id, with: DraftInput(from: from, subject: "x", version: draft.version))
        }

        let input = SendInput(from: from, to: ["a@example.net"], subject: "Hi again", text: "Body",
                              draftID: draft.id, idempotencyKey: "key-1")
        let sent = try await rig.api.send(input)
        let replay = try await rig.api.send(input)
        #expect(sent.id == replay.id)
        #expect(rig.server.counters.sends == 1, "an idempotent replay was sent twice")
        #expect(rig.server.counters.sendRequests == 2)
        #expect(rig.server.draftCount == 0, "the send did not consume its draft")

        let candidates = try await rig.api.signatures(from: from)
        #expect(candidates.signatures.isEmpty)

        let extra = try await rig.api.createDraft(DraftInput(from: from, subject: "Delete me"))
        try await rig.api.deleteDraft(id: extra.id)
        #expect(rig.server.counters.draftDeletes == 1)
    }
}

@Suite struct ScriptedSignInPresenterTests {
    nonisolated static let authorize = URL(string: "https://hqbase.uitest.invalid/api/auth/oauth2/authorize?state=abc")!
    nonisolated static let callback = URL(string: "com.wizemann.herald:/oauth/callback?code=c&state=abc")!

    static func presenter(_ mode: SignInPresenterMode) -> ScriptedSignInPresenter {
        ScriptedSignInPresenter(mode: mode, issueCallback: { _ in callback })
    }

    @Test func succeedFailAndUserCancel() async throws {
        #expect(try await Self.presenter(.succeed).authorize(url: Self.authorize, callbackScheme: "x") == Self.callback)
        await #expect(throws: OAuthError.webAuthenticationFailed("Nope")) {
            _ = try await Self.presenter(.fail("Nope")).authorize(url: Self.authorize, callbackScheme: "x")
        }
        await #expect(throws: OAuthError.userCancelled) {
            _ = try await Self.presenter(.userCancel).authorize(url: Self.authorize, callbackScheme: "x")
        }
    }

    /// Fails if a hung sign-in ignores cancellation — Herald's Cancel would
    /// then leave the attempt (and its claim on the account) alive forever.
    @Test(.timeLimit(.minutes(1)))
    func hangHonoursCancellation() async throws {
        let presenter = Self.presenter(.hangUntilCancelled)
        let attempt = Task { try await presenter.authorize(url: Self.authorize, callbackScheme: "x") }
        try await waitFor { presenter.pendingCount == 1 }
        attempt.cancel()
        await #expect(throws: OAuthError.userCancelled) { _ = try await attempt.value }
        #expect(presenter.pendingCount == 0)
    }

    /// The cancel can land before the wait parks; it must still end the wait.
    @Test(.timeLimit(.minutes(1)))
    func cancelBeforeTheWaitParks() async throws {
        let presenter = Self.presenter(.hangUntilCancelled)
        let attempt = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await presenter.authorize(url: Self.authorize, callbackScheme: "x")
        }
        await #expect(throws: OAuthError.userCancelled) { _ = try await attempt.value }
        #expect(presenter.pendingCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func completePendingReleasesAHang() async throws {
        let presenter = Self.presenter(.hangUntilCancelled)
        let attempt = Task { try await presenter.authorize(url: Self.authorize, callbackScheme: "x") }
        try await waitFor { presenter.pendingCount == 1 }
        presenter.completePending()
        #expect(try await attempt.value == Self.callback)
        #expect(presenter.attemptCount == 1)
    }

    private func waitFor(_ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("timed out")
    }
}
