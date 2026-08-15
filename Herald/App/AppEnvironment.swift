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
            logger.error("Mail cache unavailable: \(error.localizedDescription, privacy: .public)")
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
            logger.error("Account list unreadable: \(error.localizedDescription, privacy: .public)")
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
            let api = HQBaseAPIClient(origin: account.origin, tokens: tokens)
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
            self.mail = viewModel
            phase = .ready
            await viewModel.start()
            await engine.start(accountID: account.id)
        } catch {
            logger.error("Account activation failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
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
            logger.warning("Sign-in failed: \(error.localizedDescription, privacy: .public)")
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
        mail?.stop()
        if let engine = syncEngine { await engine.stop() }
        if let account {
            do {
                try auth.signOut(account)
            } catch {
                logger.error("Sign-out failed: \(error.localizedDescription, privacy: .public)")
                signInError = error.localizedDescription
            }
        }
        if let store, let accountID = account?.id {
            do {
                try await store.deleteAll(accountID: accountID)
            } catch {
                logger.error("Cache purge failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        syncEngine = nil
        mail = nil
        account = nil
        phase = .signedOut
    }

    func setWindowActive(_ active: Bool) async {
        await mail?.setActive(active)
    }
}
