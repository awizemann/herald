import AppKit
import Foundation
import HeraldKit
import OSLog
import SwiftData

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "AppEnvironment")

/// One account's live object graph: everything built from that account's API
/// client, kept together so it can be started and torn down as a unit.
///
/// Every account has one of these for as long as it is signed in — including the
/// accounts the window is NOT showing, so their sync keeps running and their
/// unread counts stay live.
@MainActor
final class AccountGraph {
    let account: Account
    let sync: SyncEngine
    let mail: MailViewModel
    let outbox: OutboxService
    /// Per-account: its "already announced" history dies with the graph, so a
    /// sign-out and a fresh sign-in cannot silence the new account's first mail.
    let notifier: NewMailNotifier

    init(
        account: Account,
        sync: SyncEngine,
        mail: MailViewModel,
        outbox: OutboxService,
        notifier: NewMailNotifier
    ) {
        self.account = account
        self.sync = sync
        self.mail = mail
        self.outbox = outbox
        self.notifier = notifier
    }

    /// `stopAndWait`, not `stop`: sign-out purges this account's rows immediately
    /// afterwards, and a pass still unwinding would write them back in behind the
    /// purge.
    func stop() async {
        mail.stop()
        await sync.stopAndWait()
    }
}

/// The composition root: opens the cache, restores every signed-in account and
/// wires Keychain → auth → API client → sync + actions → view-model per account.
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
    /// Set while the onboarding sheet is running a sign-in.
    private(set) var isSigningIn = false
    var signInError: String?
    /// Drives the "Add Account…" sheet over the mail UI.
    var presentsAddAccount = false

    /// Every signed-in account's live graph, keyed by account id.
    private(set) var graphs: [Account.ID: AccountGraph] = [:]
    /// Presentation order of ``graphs`` — a dictionary has none, and the account
    /// switcher must not reshuffle itself on every keystroke.
    private(set) var accountIDs: [Account.ID] = []

    /// Which account the window is showing. Persisted, so a relaunch comes back
    /// to the account the user was last reading.
    var selectedAccountID: Account.ID? {
        didSet {
            guard selectedAccountID != oldValue else { return }
            if let selectedAccountID {
                defaults.set(selectedAccountID, forKey: Self.selectedAccountKey)
            } else {
                defaults.removeObject(forKey: Self.selectedAccountKey)
            }
        }
    }

    nonisolated static let selectedAccountKey = "selectedAccountID"

    /// A compose window's resolved payload, plus the account it was opened from.
    ///
    /// The window scene can only carry a Codable id, so the payload lives here —
    /// and the ACCOUNT has to live here with it, or a composer opened from one
    /// account would send through whichever account happened to be selected when
    /// the user pressed Send.
    private struct ComposeSession {
        let accountID: Account.ID
        let context: ComposeContext
        /// The live composer. Owned here so the window's `.task(id:)` — which
        /// re-runs whenever SwiftUI rebuilds the scene root — finds the SAME
        /// instance, with whatever the user has typed into it, instead of
        /// building a second one over a half-written message.
        var model: ComposeViewModel?
    }

    private var composeSessions: [ComposeRequest.ID: ComposeSession] = [:]
    /// Watches app-level activation to drive the sync cadence.
    private var activityTask: Task<Void, Never>?

    private let auth: AuthCoordinator
    private let defaults: UserDefaults
    private var container: ModelContainer?
    private var store: MailStore?

    /// The notification centre behind ``NewMailNotificationPosting``. ONE for the
    /// whole app (the system centre is a singleton), shared by every account's
    /// notifier. Injected so tests never touch `UNUserNotificationCenter`, which
    /// needs a real bundle and prompts a human.
    private let notificationPoster: any NewMailNotificationPosting
    /// Kept alive here: `UNUserNotificationCenter.delegate` is a weak reference,
    /// so a router that only lived in `start()` would be gone before the first
    /// click.
    private var notificationRouter: NewMailNotificationRouter?
    /// A banner clicked before its account's graph existed (the click that
    /// launched Herald), replayed once that account installs.
    private var pendingRoute: NewMailRoute?

    init(
        auth: AuthCoordinator = AuthCoordinator(),
        defaults: UserDefaults = .standard,
        notificationPoster: any NewMailNotificationPosting = UserNotificationCenterAdapter()
    ) {
        self.auth = auth
        self.defaults = defaults
        self.notificationPoster = notificationPoster
    }

    // MARK: - Derived state

    /// The accounts the switcher lists, in a stable order.
    var accounts: [Account] { accountIDs.compactMap { graphs[$0]?.account } }

    var selectedGraph: AccountGraph? { selectedAccountID.flatMap { graphs[$0] } }

    /// What the window shows. Every other graph keeps syncing behind it.
    var mail: MailViewModel? { selectedGraph?.mail }

    /// One line of the account switcher: the account's label and the host it
    /// talks to, because two accounts on the same provider default to labels
    /// that only the host tells apart. Pure and static so the popup's text is
    /// assertable without a rendered `Picker`.
    nonisolated static func accountPickerLabel(for account: Account, unread: Int) -> String {
        let host = account.origin.host ?? account.origin.absoluteString
        let base = account.label == host ? host : "\(account.label) — \(host)"
        return unread > 0 ? "\(base) (\(unread))" : base
    }

    /// The menu item names the account once there is more than one — an
    /// unqualified "Sign Out" does not say which server it burns.
    var signOutMenuTitle: String {
        guard accountIDs.count > 1, let label = selectedGraph?.account.label else { return "Sign Out" }
        return "Sign Out of \(label)"
    }

    /// Inbox unread for one account, whether or not it is the selected one.
    func unreadCount(forAccount id: Account.ID) -> Int {
        graphs[id]?.mail.pickerUnread(forMailbox: nil) ?? 0
    }

    /// Unread across ALL accounts — the inbox count of every signed-in account,
    /// which is what a Dock badge would show.
    var totalUnreadCount: Int {
        accountIDs.reduce(0) { $0 + (graphs[$1]?.mail.pickerUnread(forMailbox: nil) ?? 0) }
    }

    // MARK: - Launch

    func start() async {
        observeActivation()
        installNotificationRouter()
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
        await restoreAccounts()
    }

    private func restoreAccounts() async {
        let accounts: [Account]
        do {
            accounts = try auth.accounts()
        } catch {
            logger.error("Account list unreadable: \(error.localizedDescription, privacy: .private)")
            phase = .failed(error.localizedDescription)
            return
        }
        guard !accounts.isEmpty else {
            phase = .signedOut
            return
        }
        // The remembered account comes up FIRST and alone: every other account's
        // activation is a discovery round trip, and restoring them in line would
        // hold the whole window on the launch placeholder until the slowest —
        // or unreachable — server answered.
        var ordered = accounts
        if let remembered = defaults.string(forKey: Self.selectedAccountKey),
           let index = ordered.firstIndex(where: { $0.id == remembered }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        await activate(ordered[0])
        let rest = ordered.dropFirst()
        if graphs.isEmpty, rest.isEmpty {
            // The user HAS an account and it did not come up. `activate` already
            // said why, and overwriting that with `.signedOut` would replace a
            // real explanation with the onboarding sheet. (With others still to
            // try, nothing is decided yet — one of them will set the phase.)
            if case .failed = phase {} else { phase = .signedOut }
        }
        guard !rest.isEmpty else { return }
        // The rest come up behind the live window, and must not steal it.
        Task { [weak self] in
            for account in rest { await self?.activate(account, select: false) }
        }
    }

    /// Builds one account's graph and hands its view-model its feeds.
    ///
    /// `select: false` is for the accounts a restore brings up behind whatever
    /// the window is already showing.
    private func activate(_ account: Account, select: Bool = true) async {
        guard let store else { return }
        do {
            let tokens = try await auth.tokenProvider(for: account)
            await install(
                account: account,
                api: HQBaseAPIClient(origin: account.origin, tokens: tokens),
                store: store,
                select: select
            )
        } catch {
            logger.error("Account activation failed: \(error.localizedDescription, privacy: .private)")
            // One unreachable account must not take the whole app down when
            // another one is working.
            if graphs.isEmpty {
                phase = .failed(error.localizedDescription)
            } else {
                signInError = error.localizedDescription
            }
        }
    }

    /// Installs (or replaces) ONE account's graph and selects it. Internal so
    /// tests can drive it with a fake API client instead of a real signed-in
    /// account.
    ///
    /// Re-installing the same account — which is what re-authentication does —
    /// stops the superseded graph, or its `SyncEngine` would keep polling
    /// forever and its `MailViewModel` would keep consuming that engine's events.
    /// Every OTHER account is left running.
    ///
    /// The new graph is published BEFORE the old one is stopped, and the install
    /// re-checks that it is still the current graph after every suspension: two
    /// overlapping installs of the same account (a double-tapped "Sign In" on the
    /// re-auth banner) would otherwise both survive, one of them unreachable from
    /// ``graphs`` and polling forever with nothing able to stop it.
    func install(
        account: Account,
        api: any MailAPIClient,
        store: MailStore,
        select: Bool = true
    ) async {
        // All accounts share the one container; keeping the reference here is
        // what lets sign-out purge THIS account's rows out of it.
        self.store = store
        let engine = SyncEngine(api: api, store: store)
        let notifier = NewMailNotifier(center: notificationPoster, lookup: store)
        let viewModel = MailViewModel(
            accountID: account.id,
            accountLabel: account.label,
            api: api,
            store: store,
            actions: MailActionService(api: api, store: store),
            sync: engine,
            events: engine.events,
            defaults: defaults,
            notifier: notifier
        )
        // The badge is the SUM across accounts, so any account's count changing
        // re-reads all of them rather than trusting the number it was handed.
        viewModel.unreadCountDidChange = { [weak self] _ in
            self?.applyDockBadge()
        }
        let graph = AccountGraph(
            account: account,
            sync: engine,
            mail: viewModel,
            outbox: OutboxService(api: api),
            notifier: notifier
        )
        // Published synchronously, so no second install can slip in and be
        // forgotten.
        let superseded = graphs.updateValue(graph, forKey: account.id)
        if !accountIDs.contains(account.id) { accountIDs.append(account.id) }
        // Selecting is what puts this account in the window. A restore bringing
        // the OTHER accounts up must not steal it — but an empty window beats
        // nothing, so a live graph is selected when none is showing.
        if select || selectedGraph == nil { selectedAccountID = account.id }
        phase = .ready
        if let superseded {
            // Its composers point at an OutboxService that is about to go away.
            closeComposeSessions(accountID: account.id)
            await superseded.stop()
        }
        guard isCurrent(graph) else { return await graph.stop() }
        await viewModel.start()
        // Seed the cadence from the app's CURRENT activation; the notifications
        // only report changes, and a launch into the foreground fires neither.
        await viewModel.setActive(NSApplication.shared.isActive)
        // Re-checked because starting a graph that has already been superseded
        // is exactly how an unowned polling loop is born.
        guard isCurrent(graph) else { return await graph.stop() }
        await engine.start(accountID: account.id)
        // A banner clicked before THIS account was up (the click that launched
        // Herald) is replayed now that its graph can answer.
        if let route = pendingRoute, route.accountID == account.id {
            pendingRoute = nil
            await open(route)
        }
    }

    /// Whether this graph is still the one ``graphs`` holds for its account.
    private func isCurrent(_ graph: AccountGraph) -> Bool {
        graphs[graph.account.id] === graph
    }

    /// Stops and drops one account's graph, leaving the others alone. The
    /// account keeps its place in ``accountIDs`` so a re-install (re-auth) does
    /// not shuffle the switcher.
    private func stopGraph(accountID: Account.ID) async {
        guard let graph = graphs.removeValue(forKey: accountID) else { return }
        closeComposeSessions(accountID: accountID)
        await graph.stop()
        // That account's unread is no longer part of the total; a badge that
        // still counts a signed-out account is a lie.
        applyDockBadge()
    }

    // MARK: - Notifications and the Dock badge

    private func installNotificationRouter() {
        guard notificationRouter == nil else { return }
        let router = NewMailNotificationRouter { [weak self] route in
            await self?.open(route)
        }
        notificationRouter = router
        router.install()
    }

    /// Where a clicked banner lands: the account it names becomes the selected
    /// one, then THAT account's view-model shows the conversation.
    ///
    /// Switching the window is right here, unlike a background action doing it:
    /// the banner said which account the mail is in, so the switcher following
    /// the click is what the user asked for.
    func open(_ route: NewMailRoute) async {
        // Clicking a banner can LAUNCH Herald — or name an account still coming
        // up behind the first one, since a restore activates the rest in the
        // background. Held until that account installs rather than dropped.
        guard let graph = graphs[route.accountID] else {
            pendingRoute = route
            return
        }
        selectedAccountID = route.accountID
        guard let threadID = route.threadID else { return }
        await graph.mail.revealConversation(threadID: threadID)
    }

    /// Re-applies the badge from the live counts. Called by Settings so flipping
    /// the switch shows (or clears) the badge at once.
    ///
    /// The number is ``totalUnreadCount``: the Dock shows ONE badge for Herald,
    /// so an account syncing behind the window still counts toward it.
    func applyDockBadge() {
        DockBadge.apply(
            count: totalUnreadCount,
            enabled: NotificationSettings.dockBadgeEnabled(in: defaults)
        )
    }

    /// Asks for permission the moment the user turns notifications on, so the
    /// system prompt is tied to the action that needs it rather than to whichever
    /// message happens to arrive first.
    func notificationsSettingChanged(enabled: Bool) async {
        guard enabled else { return }
        guard !graphs.isEmpty else {
            // Opted in before signing in: still ask, so the prompt belongs to the
            // switch the user just flipped rather than to the first mail to land.
            _ = await notificationPoster.requestAuthorization()
            return
        }
        // Each account's notifier caches the answer; the system prompts once and
        // hands the rest the stored result.
        for id in accountIDs {
            guard let notifier = graphs[id]?.notifier else { continue }
            await notifier.ensureAuthorized()
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
            logger.warning("Sign-in failed: \(error.localizedDescription, privacy: .private)")
            signInError = error.localizedDescription
        }
    }

    /// Re-runs the whole flow for the ONE account whose token died. The other
    /// accounts keep syncing throughout.
    func reauthenticate(accountID: Account.ID?) async {
        guard let accountID, let account = graphs[accountID]?.account else {
            if graphs.isEmpty { phase = .signedOut }
            return
        }
        await signIn(originText: account.origin.absoluteString)
        // The same origin can come back under a DIFFERENT id (a different user
        // signed in). `install` then keys the new graph elsewhere and the dead
        // one would be left polling with a token nothing can refresh.
        if let current = selectedAccountID, current != accountID {
            await stopGraph(accountID: accountID)
            accountIDs.removeAll { $0 == accountID }
        }
    }

    /// Signs ONE account out: its graph stops, its cached rows are purged, and
    /// the window falls back to whatever account is left.
    func signOut(accountID: Account.ID?) async {
        guard let accountID else { return }
        // An account whose graph never came up (its server was unreachable at
        // launch) is still signed in as far as the Keychain is concerned, so the
        // account list is the fallback — otherwise it could never be removed.
        guard let account = graphs[accountID]?.account
            ?? (try? auth.accounts())?.first(where: { $0.id == accountID })
        else { return }
        await stopGraph(accountID: accountID)
        accountIDs.removeAll { $0 == accountID }
        // The window settles BEFORE the slow half. Revocation is a network round
        // trip and the purge is a store write; leaving `selectedAccountID`
        // pointing at a graph that is already gone renders a launch placeholder
        // over the surviving account, and a switcher whose selection has no tag.
        if selectedAccountID == accountID { selectedAccountID = accountIDs.first }
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

    // MARK: - Compose

    /// Resolves a compose request into a context and returns the id the compose
    /// window should be opened with. `nil` means there is nothing to compose
    /// (no account yet, or the message could not be loaded).
    func prepareCompose(_ request: ComposeRequest) async -> ComposeRequest.ID? {
        guard let graph = selectedGraph else { return nil }
        guard let context = await graph.mail.composeContext(for: request),
              // The account can be signed out inside that fetch; a session with
              // no graph behind it can never build a composer, and never be
              // released either.
              isCurrent(graph)
        else { return nil }
        composeSessions[request.id] = ComposeSession(accountID: graph.account.id, context: context)
        return request.id
    }

    /// The window's view-model: the same instance for the same request id, for as
    /// long as that composer is open, and always wired to the `OutboxService` of
    /// the account it was opened from. A closed composer is not resurrected — the
    /// window shows "no longer available" rather than a copy of a sent message.
    func makeComposeViewModel(id: ComposeRequest.ID) -> ComposeViewModel? {
        guard var session = composeSessions[id] else { return nil }
        if let existing = session.model {
            guard existing.isClosed else { return existing }
            releaseComposeViewModel(id: id)
            return nil
        }
        guard let outbox = graphs[session.accountID]?.outbox else { return nil }
        let model = ComposeViewModel(context: session.context, outbox: outbox)
        session.model = model
        composeSessions[id] = session
        return model
    }

    /// The account a composer sends through. Test seam: the binding is otherwise
    /// only observable by watching which server the draft lands on.
    func composeAccountID(for id: ComposeRequest.ID) -> Account.ID? {
        composeSessions[id]?.accountID
    }

    /// Called when a compose window goes away. Drops the composer ONLY if it
    /// really is closed: a window that is merely being rebuilt must find its
    /// view-model — with its unsaved text — still here.
    func releaseComposeViewModel(id: ComposeRequest.ID) {
        guard composeSessions[id]?.model?.isClosed ?? false else { return }
        composeSessions[id] = nil
    }

    /// Signing an account out takes its compose windows' view-models with it —
    /// their `OutboxService` is gone, so leaving them alive leaves autosave tasks
    /// running against a server the app no longer has a token for.
    private func closeComposeSessions(accountID: Account.ID) {
        for (id, session) in composeSessions where session.accountID == accountID {
            session.model?.stop()
            composeSessions[id] = nil
        }
    }

    func setWindowActive(_ active: Bool) async {
        // EVERY account follows the app's activation: an account the window is
        // not showing still has to notice new mail at the active cadence, or its
        // unread count goes stale until the user switches to it.
        //
        // A snapshot on purpose — an account signed out mid-loop just gets a
        // cadence change on a stopped engine, and one installed mid-loop seeds
        // its own cadence in `install`.
        for graph in Array(graphs.values) { await graph.mail.setActive(active) }
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
