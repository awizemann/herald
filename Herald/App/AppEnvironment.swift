import AppKit
import Foundation
import HeraldKit
import OSLog
import SwiftData

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "AppEnvironment")

/// The composition root: opens the cache, restores the account and wires
/// Keychain → auth → API client → sync + actions → view-model.
///
/// Nothing here blocks `App.init`: the container is opened on a detached task and
/// the UI shows the real milestone it is waiting on.
@MainActor
@Observable
final class AppEnvironment {
    /// What the root view renders. Each launching case names a real step, so the
    /// placeholder never lies about progress.
    enum Phase: Equatable {
        case openingCache
        case restoringAccount
        case signedOut
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .openingCache
    private(set) var mail: MailViewModel?
    /// Set while the onboarding sheet is running a sign-in.
    private(set) var isSigningIn = false
    var signInError: String?
    /// Drives the "Add Account…" sheet over the mail UI. P0 shows one account at
    /// a time, so adding one replaces what the window is showing.
    var presentsAddAccount = false

    /// Compose contexts waiting for (or backing) an open compose window, keyed by
    /// the request that produced them. The window scene can only carry a Codable
    /// id, so the resolved payload lives here.
    private var composeContexts: [ComposeRequest.ID: ComposeContext] = [:]
    /// Live compose view-models, keyed the same way.
    ///
    /// The window's `.task(id:)` re-runs whenever SwiftUI rebuilds the scene's
    /// root, and the old code CONSUMED the context on the way through — so the
    /// second run built nothing and the half-written message became "this draft
    /// is no longer available". The instance is owned here and handed back
    /// idempotently instead, and dropped only once the composer says it closed.
    private var composeViewModels: [ComposeRequest.ID: ComposeViewModel] = [:]
    private var outbox: OutboxService?
    /// Watches app-level activation to drive the sync cadence.
    private var activityTask: Task<Void, Never>?

    private let auth: AuthCoordinator
    private var container: ModelContainer?
    private var store: MailStore?
    private var syncEngine: SyncEngine?
    private var account: Account?

    init(auth: AuthCoordinator = AuthCoordinator()) {
        self.auth = auth
    }

    var accountLabel: String? { account?.label }

    // MARK: - Launch

    func start() async {
        observeActivation()
        phase = .openingCache
        let url = MailStoreContainer.defaultStoreURL
        do {
            // Opening a SwiftData store is file I/O; `make(url:)` is nonisolated
            // precisely so it can run off the main actor.
            let container = try await Task.detached(priority: .userInitiated) { @Sendable in
                try MailStoreContainer.make(url: url)
            }.value
            self.container = container
            self.store = MailStore(modelContainer: container)
        } catch {
            logger.error("Mail cache unavailable: \(error.localizedDescription, privacy: .private)")
            phase = .failed("Herald could not open its local mail cache. \(error.localizedDescription)")
            return
        }

        phase = .restoringAccount
        await restoreAccount()
    }

    private func restoreAccount() async {
        let accounts: [Account]
        do {
            accounts = try auth.accounts()
        } catch {
            logger.error("Account list unreadable: \(error.localizedDescription, privacy: .private)")
            phase = .failed(error.localizedDescription)
            return
        }
        // P0 is single-account UI; the model already supports several.
        guard let account = accounts.first else {
            phase = .signedOut
            return
        }
        await activate(account)
    }

    /// Builds the per-account object graph and hands the view-model its feeds.
    private func activate(_ account: Account) async {
        guard let store else { return }
        do {
            let tokens = try await auth.tokenProvider(for: account)
            await install(
                account: account,
                api: HQBaseAPIClient(origin: account.origin, tokens: tokens),
                store: store
            )
        } catch {
            logger.error("Account activation failed: \(error.localizedDescription, privacy: .private)")
            phase = .failed(error.localizedDescription)
        }
    }

    /// Replaces the live per-account graph. Internal so tests can drive it with a
    /// fake API client instead of a real signed-in account.
    func install(account: Account, api: any MailAPIClient, store: MailStore) async {
        // Adding a second account (or re-authenticating) used to build a new graph
        // on top of the old one: the previous SyncEngine kept polling forever and
        // the previous MailViewModel kept consuming its events.
        await teardownGraph()
        let engine = SyncEngine(api: api, store: store)
        let viewModel = MailViewModel(
            accountID: account.id,
            accountLabel: account.label,
            api: api,
            store: store,
            actions: MailActionService(api: api, store: store),
            sync: engine,
            events: engine.events
        )
        self.account = account
        self.syncEngine = engine
        self.outbox = OutboxService(api: api)
        self.mail = viewModel
        phase = .ready
        await viewModel.start()
        // Seed the cadence from the app's CURRENT activation; the notifications
        // only report changes, and a launch into the foreground fires neither.
        await viewModel.setActive(NSApplication.shared.isActive)
        await engine.start(accountID: account.id)
    }

    /// Stops and drops whatever account graph is currently live.
    private func teardownGraph() async {
        mail?.stop()
        // `stopAndWait`, not `stop`: sign-out and account switch both purge the
        // cache immediately afterwards, and a pass still unwinding would write
        // the OLD account's rows in behind the purge.
        if let engine = syncEngine { await engine.stopAndWait() }
        syncEngine = nil
        outbox = nil
        composeContexts.removeAll()
        composeViewModels.values.forEach { $0.stop() }
        composeViewModels.removeAll()
        mail = nil
    }

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

    func signIn(originText: String) async {
        guard let origin = Self.normalizedOrigin(from: originText) else {
            signInError = "Enter the https address of your HQBase server, for example https://mail.example.com"
            return
        }
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }
        do {
            let account = try await auth.addAccount(origin: origin)
            presentsAddAccount = false
            await activate(account)
        } catch {
            logger.warning("Sign-in failed: \(error.localizedDescription, privacy: .private)")
            signInError = error.localizedDescription
        }
    }

    /// Re-runs the whole flow for the account whose token died.
    func reauthenticate() async {
        guard let account else {
            phase = .signedOut
            return
        }
        await signIn(originText: account.origin.absoluteString)
    }

    func signOut() async {
        await teardownGraph()
        if let account {
            do {
                try await auth.signOut(account)
            } catch {
                logger.error("Sign-out failed: \(error.localizedDescription, privacy: .private)")
                signInError = error.localizedDescription
            }
        }
        if let store, let accountID = account?.id {
            do {
                try await store.deleteAll(accountID: accountID)
            } catch {
                logger.error("Cache purge failed: \(error.localizedDescription, privacy: .private)")
            }
        }
        account = nil
        phase = .signedOut
    }

    // MARK: - Compose

    /// Resolves a compose request into a context and returns the id the compose
    /// window should be opened with. `nil` means there is nothing to compose
    /// (no account yet, or the message could not be loaded).
    func prepareCompose(_ request: ComposeRequest) async -> ComposeRequest.ID? {
        guard let mail, outbox != nil else { return nil }
        guard let context = await mail.composeContext(for: request) else { return nil }
        composeContexts[request.id] = context
        return request.id
    }

    /// The window's view-model: the same instance for the same request id, for as
    /// long as that composer is open. A closed composer is not resurrected — the
    /// window shows "no longer available" rather than a copy of a sent message.
    func makeComposeViewModel(id: ComposeRequest.ID) -> ComposeViewModel? {
        if let existing = composeViewModels[id] {
            guard existing.isClosed else { return existing }
            releaseComposeViewModel(id: id)
            return nil
        }
        guard let outbox, let context = composeContexts[id] else { return nil }
        let model = ComposeViewModel(context: context, outbox: outbox)
        composeViewModels[id] = model
        return model
    }

    /// Called when a compose window goes away. Drops the composer ONLY if it
    /// really is closed: a window that is merely being rebuilt must find its
    /// view-model — with its unsaved text — still here.
    func releaseComposeViewModel(id: ComposeRequest.ID) {
        guard composeViewModels[id]?.isClosed ?? false else { return }
        composeViewModels[id] = nil
        composeContexts[id] = nil
    }

    func setWindowActive(_ active: Bool) async {
        await mail?.setActive(active)
    }

    // MARK: - Activation

    /// Sync cadence follows the APPLICATION's activation, not a window's
    /// `scenePhase`. Per-window scenePhase flaps: opening a compose window moves
    /// the key window off the mail window, the mail scene reports inactive, and
    /// the engine backs off to the idle cadence while the user is plainly using
    /// the app.
    private func observeActivation() {
        activityTask?.cancel()
        activityTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @Sendable [weak self] in
                    let active = NotificationCenter.default.notifications(
                        named: NSApplication.didBecomeActiveNotification
                    )
                    for await _ in active { await self?.setWindowActive(true) }
                }
                group.addTask { @Sendable [weak self] in
                    let resigned = NotificationCenter.default.notifications(
                        named: NSApplication.didResignActiveNotification
                    )
                    for await _ in resigned { await self?.setWindowActive(false) }
                }
            }
        }
    }
}
