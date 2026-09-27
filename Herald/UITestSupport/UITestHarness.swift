#if DEBUG
import Foundation
import HeraldKit
import Observation
import os
import SwiftData

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "uitest")

/// The Debug-only UI-test composition root: every dependency ``AppEnvironment``
/// takes, replaced by an in-process fake.
///
/// | Real                                   | Test mode                                     |
/// |----------------------------------------|-----------------------------------------------|
/// | Keychain (`KeychainAccountStore`)      | ``InMemoryAccountStore``                      |
/// | `ASWebAuthenticationSession`           | ``ScriptedSignInPresenter``                   |
/// | Auth + REST sessions (`URLSession`)    | ``FakeHQBaseNetwork/makeSession()``           |
/// | `GET /events` WebSocket                | ``FakeEventChannels`` (refused, 503)          |
/// | On-disk SwiftData cache                | in-memory container                           |
/// | `UserDefaults.standard`                | a throwaway suite, wiped at launch            |
/// | `UNUserNotificationCenter`             | ``SilentNotificationPoster``, no delegate     |
/// | swift-stats analytics                  | `NoopUsageTracker`                            |
/// | Sparkle                                | not started (``UpdateService``)               |
///
/// Built only by ``launched`` (from the process arguments) and by unit tests.
@MainActor
@Observable
final class UITestHarness {
    /// The throwaway defaults suite. Never the app's own domain, which Debug
    /// and Release share (both are `com.wizemann.herald`).
    nonisolated static let defaultsSuiteName = "com.wizemann.herald.uitest"

    /// The harness for THIS process, or `nil` in a normal launch. A malformed
    /// test-mode request stops the launch here rather than falling through to
    /// the real Keychain and network.
    static let launched: UITestHarness? = {
        do {
            guard let configuration = try UITestLaunchConfiguration.parse(arguments: ProcessInfo.processInfo.arguments) else {
                return nil
            }
            logger.notice("UI-test mode: scenario \(configuration.scenario.rawValue, privacy: .public)")
            // AppKit's window restoration lives in the app's container, which
            // Debug and Release share: never restore the real app's windows
            // into a test run, never save the test run's for the real app.
            // The REGISTRATION domain is volatile — nothing is written.
            UserDefaults.standard.register(defaults: [
                "ApplePersistenceIgnoreState": true,
                "NSQuitAlwaysKeepsWindows": false,
            ])
            return UITestHarness(configuration: configuration)
        } catch {
            fatalError("Herald UI-test launch refused: \(error)")
        }
    }()

    @ObservationIgnored let configuration: UITestLaunchConfiguration
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let accountStore: InMemoryAccountStore
    @ObservationIgnored let network: FakeHQBaseNetwork
    @ObservationIgnored let presenter: ScriptedSignInPresenter
    @ObservationIgnored let session: URLSession
    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored private let relay: UITestChangeRelay

    /// Mirrors of the fakes' state, refreshed on every change they report, so
    /// SwiftUI (the status label, the control menu) can observe them.
    private(set) var serverState: FakeHQBaseState
    private(set) var presenterMode: SignInPresenterMode
    private(set) var counters = FakeHQBaseCounters()
    private(set) var signInAttempts = 0
    private(set) var pendingSignIns = 0
    private(set) var accountStoreRefusesList = false

    init(configuration: UITestLaunchConfiguration, defaultsSuiteName: String = UITestHarness.defaultsSuiteName) {
        self.configuration = configuration
        serverState = configuration.serverState
        presenterMode = configuration.presenterMode

        // Wiped at every launch: a UI test starts from nothing it did not seed.
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            fatalError("Herald UI-test mode could not open its defaults suite")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        self.defaults = defaults

        var servers = [FakeHQBase(origin: UITestOrigins.primary, mailboxAddress: "me@hqbase.uitest.invalid")]
        if configuration.scenario == .twoAccounts {
            servers.append(FakeHQBase(origin: UITestOrigins.secondary, mailboxAddress: "me@second.uitest.invalid"))
        }
        let network = FakeHQBaseNetwork(servers: servers)
        self.network = network
        let session = network.makeSession()
        self.session = session

        let relay = UITestChangeRelay()
        self.relay = relay
        presenter = ScriptedSignInPresenter(
            mode: configuration.presenterMode,
            issueCallback: { [network] url in
                guard let server = network.server(for: url) else {
                    throw OAuthError.webAuthenticationFailed("UI test: no fake server answers at this address.")
                }
                return try server.approveAuthorization(url)
            },
            didChange: { relay.fire() }
        )

        let store = InMemoryAccountStore()
        accountStore = store
        if configuration.scenario != .signedOut {
            for server in servers { Self.seedSignedInAccount(on: server, into: store) }
        }
        for server in servers {
            server.setState(configuration.serverState)
            server.setObserver { relay.fire() }
        }

        environment = AppEnvironment(
            auth: AuthCoordinator(store: store, presenter: presenter, session: session),
            defaults: defaults,
            notificationPoster: SilentNotificationPoster(),
            usage: NoopUsageTracker(),
            makeMailContainer: { try MailStoreContainer.make(inMemory: true) },
            apiSession: session,
            makeEventChannels: { [network] origin in FakeEventChannels(server: network.server(for: origin)) },
            routesNotificationClicks: false
        )

        relay.set { [weak self] in
            Task { @MainActor [weak self] in self?.refreshMirrors() }
        }
        refreshMirrors()
    }

    /// One account as a completed sign-in leaves it: a registered client, a
    /// live grant in the (fake) Keychain, and a few Inbox messages server-side.
    private static func seedSignedInAccount(on server: FakeHQBase, into store: InMemoryAccountStore) {
        let clientID = "uitest-\(server.host.split(separator: ".").first ?? "x")-seed-client"
        let tokens = server.seedGrant(clientID: clientID)
        server.seedInbox()
        let account = Account(origin: server.origin, clientID: clientID, scopes: tokens.scopes)
        do {
            try store.setClientID(clientID, for: server.origin)
            try store.add(account)
            try store.setTokens(tokens, for: account.id)
        } catch {
            fatalError("UI-test seeding failed: \(error)")
        }
    }

    // MARK: - Controls (the "UI Test Controls" menu)

    func setServerState(_ state: FakeHQBaseState) {
        for server in network.all { server.setState(state) }
        logger.notice("UI-test server state: \(state.rawValue, privacy: .public)")
        refreshMirrors()
    }

    func setPresenterMode(_ mode: SignInPresenterMode) {
        presenter.mode = mode
        logger.notice("UI-test presenter: \(mode.name, privacy: .public)")
        refreshMirrors()
    }

    func completePendingSignIns() {
        presenter.completePending()
        refreshMirrors()
    }

    func setAccountStoreRefusesList(_ refuses: Bool) {
        accountStore.refusesAccountList = refuses
        refreshMirrors()
    }

    func resetCounters() {
        for server in network.all { server.resetCounters() }
        presenter.resetCounters()
        refreshMirrors()
    }

    func refreshMirrors() {
        serverState = network.all.first?.mode ?? .healthy
        presenterMode = presenter.mode
        counters = network.all.reduce(FakeHQBaseCounters()) { $0 + $1.counters }
        signInAttempts = presenter.attemptCount
        pendingSignIns = presenter.pendingCount
        accountStoreRefusesList = accountStore.refusesAccountList
    }

    /// The status line UI tests read (accessibility value of `uitest.status`).
    /// Space-separated `key=value` pairs in this fixed order; new keys are
    /// only ever appended.
    var status: String {
        [
            "server=\(serverState.rawValue)",
            "presenter=\(presenterMode.name)",
            "sends=\(counters.sends)",
            "sendRequests=\(counters.sendRequests)",
            "tokenRequests=\(counters.tokenRequests)",
            "refreshes=\(counters.refreshes)",
            "codeExchanges=\(counters.codeExchanges)",
            "registrations=\(counters.registrations)",
            "signIns=\(signInAttempts)",
            "pendingSignIns=\(pendingSignIns)",
            "draftCreates=\(counters.draftCreates)",
            "draftUpdates=\(counters.draftUpdates)",
            "draftDeletes=\(counters.draftDeletes)",
            "unauthorized=\(counters.unauthorized)",
            "revocations=\(counters.revocations)",
            "storeRefusesList=\(accountStoreRefusesList)",
        ].joined(separator: " ")
    }
}

/// Forwards "something changed" from the fakes (called on URLSession's
/// threads) to whoever is listening. Set once, after the harness exists.
nonisolated final class UITestChangeRelay: Sendable {
    private let handler = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    func set(_ handler: @escaping @Sendable () -> Void) {
        self.handler.withLock { $0 = handler }
    }

    func fire() {
        handler.withLock { $0 }?()
    }
}

/// Posts nothing and never asks for permission: test mode must not touch
/// `UNUserNotificationCenter`.
nonisolated struct SilentNotificationPoster: NewMailNotificationPosting {
    func requestAuthorization() async -> Bool { false }
    func post(_ notification: NewMailNotification) async {}
}
#endif
