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
    /// This account's `GET /events` wake socket, when it has one.
    let wake: MailEventSocket?

    init(
        account: Account,
        sync: SyncEngine,
        mail: MailViewModel,
        outbox: OutboxService,
        notifier: NewMailNotifier,
        wake: MailEventSocket? = nil
    ) {
        self.account = account
        self.sync = sync
        self.mail = mail
        self.outbox = outbox
        self.notifier = notifier
        self.wake = wake
    }

    /// `stopAndWait`, not `stop`: sign-out purges this account's rows immediately
    /// afterwards, and a pass still unwinding would write them back in behind the
    /// purge.
    func stop() async {
        mail.stop()
        // Before the engine: a socket still up would keep asking a stopping
        // engine for passes, and a superseded graph's socket left running is a
        // second connection against the server's three-per-user limit — the
        // server closes the OLDEST to make room, so a leak here would evict the
        // live account's socket.
        await wake?.stop()
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

    /// Where the running sign-in is. Named steps, because "spinner" is not a
    /// diagnosis: issue #9 was a sign-in stuck at the browser hand-off with
    /// nothing on screen or in the log to say so.
    enum SignInStage: Equatable {
        case contactingServer
        case checkingRegistration
        case registering
        case waitingForBrowser
        case completingSignIn
        case savingCredentials
        case activating

        init(_ step: AuthStep) {
            switch step {
            case .discovering: self = .contactingServer
            case .checkingRegistration: self = .checkingRegistration
            case .registering: self = .registering
            case .presenting: self = .waitingForBrowser
            case .exchanging: self = .completingSignIn
            case .saving: self = .savingCredentials
            }
        }

        /// The caption under the spinner.
        var message: String {
            switch self {
            case .contactingServer: "Contacting your server…"
            case .checkingRegistration: "Checking this Mac's registration…"
            case .registering: "Registering Herald with your server…"
            case .waitingForBrowser: "Waiting for the sign-in window…"
            case .completingSignIn: "Completing sign-in…"
            case .savingCredentials: "Saving your credentials…"
            case .activating: "Setting up your mailbox…"
            }
        }

        /// Log-safe name. Stable, never localized, never a server address.
        var logName: String {
            switch self {
            case .contactingServer: "contactingServer"
            case .checkingRegistration: "checkingRegistration"
            case .registering: "registering"
            case .waitingForBrowser: "waitingForBrowser"
            case .completingSignIn: "completingSignIn"
            case .savingCredentials: "savingCredentials"
            case .activating: "activating"
            }
        }
    }

    private(set) var phase: Phase = .openingCache
    /// Set while the onboarding sheet is running a sign-in.
    private(set) var isSigningIn = false
    /// The step the visible sign-in is on; `nil` when none is running. Only ever
    /// set by an INTERACTIVE sign-in — an automatic re-auth is silent by design.
    private(set) var signInStage: SignInStage?
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
            // The account now in the window may be one whose expiry was deferred
            // because it was syncing behind it.
            Task { [weak self] in await self?.retryAutomaticReauthentication() }
            // A switch is what the USER did: launch restore, an install picking
            // up the window and a sign-out falling back all assign this too, and
            // none of them is somebody choosing an account. `nil` on either side
            // is likewise not a switch — it is the first account arriving, or the
            // last one leaving.
            guard !isAssigningAccountProgrammatically,
                  oldValue != nil, selectedAccountID != nil
            else { return }
            record(.accountSwitched(accounts: UsageBucket(count: accountIDs.count)))
        }
    }

    /// Raised around the assignments that are Herald's doing rather than the
    /// user's. Only ever set for the duration of one synchronous assignment, so
    /// nothing can observe it down across a suspension.
    @ObservationIgnored private var isAssigningAccountProgrammatically = false

    /// Assigns ``selectedAccountID`` without counting it as an account switch.
    private func selectAccount(_ id: Account.ID?) {
        isAssigningAccountProgrammatically = true
        defer { isAssigningAccountProgrammatically = false }
        selectedAccountID = id
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
    /// Whether Herald is the frontmost app. Injected so a test can drive the
    /// automatic re-auth gate without an `NSApplication` it cannot activate.
    private let isApplicationActive: @MainActor @Sendable () -> Bool
    /// The rules for re-running consent by ourselves. Observed (not
    /// `@ObservationIgnored`): the banner renders its "signing you back in…"
    /// state straight off it.
    private var autoReauth = AutoReauthPolicy()
    /// The live automatic attempts, so a sign-out can cancel one instead of
    /// letting its `install` resurrect the account behind it. Observation-ignored:
    /// the banner reads ``autoReauth``, not this.
    @ObservationIgnored private var automaticReauthTasks: [Account.ID: Task<Bool, Never>] = [:]
    /// Cancels the live INTERACTIVE sign-in. Held as a closure rather than the
    /// task itself only because the two entry points (first sign-in, re-auth)
    /// return different values; what matters is that the handle is kept at all —
    /// discarding it is what made the reported hang unrecoverable.
    @ObservationIgnored private var signInCancellation: (@Sendable () -> Void)?
    /// Bumped by every cancel and every new interactive attempt. An attempt only
    /// owns the sign-in UI — and is only allowed to install its account — while
    /// its generation is still the current one, so a session that completes after
    /// the user gave up cannot reach back and change the screen under them.
    @ObservationIgnored private var signInGeneration = 0
    /// The account a live INTERACTIVE re-auth is repairing, if any. Held so a
    /// cancel (or a sign-out) can release that account's ``AutoReauthPolicy``
    /// claim without waiting for a task that may never return.
    @ObservationIgnored private var signInReauthAccountID: Account.ID?
    /// The one usage-analytics seam for the whole app. Default ``NoopUsageTracker``,
    /// so every test — and any caller that does not opt in — collects nothing.
    let usage: any UsageTracking
    /// The tail of the record chain. Every emission awaits the previous one, so
    /// events reach the SDK in the order they happened rather than in whatever
    /// order a pile of unstructured tasks got scheduled.
    @ObservationIgnored private var pendingRecord: Task<Void, Never>?
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
        notificationPoster: any NewMailNotificationPosting = UserNotificationCenterAdapter(),
        usage: any UsageTracking = NoopUsageTracker(),
        isApplicationActive: @escaping @MainActor @Sendable () -> Bool = { NSApplication.shared.isActive }
    ) {
        self.auth = auth
        self.defaults = defaults
        self.notificationPoster = notificationPoster
        self.usage = usage
        self.isApplicationActive = isApplicationActive
    }

    // MARK: - Usage analytics

    /// Emits one event, after everything already queued. The only way anything in
    /// Herald reaches the tracker.
    func record(_ event: UsageEvent) {
        enqueueUsage { usage in await usage.track(event) }
    }

    /// The closure the view-models are handed. Weak, because a composer can
    /// outlive nothing here in practice but must never keep the environment alive.
    var recordUsage: @MainActor @Sendable (UsageEvent) -> Void {
        { [weak self] event in self?.record(event) }
    }

    /// Drives `app_open` / `session_start`. On the same chain as the events, so
    /// the session opens before whatever the user does inside it.
    func recordApplicationDidBecomeActive() {
        enqueueUsage { usage in await usage.applicationDidBecomeActive() }
    }

    /// Pushes whatever is queued. Chained for the same reason: a flush that
    /// overtook the events it was supposed to flush would send nothing.
    func recordFlush() {
        enqueueUsage { usage in await usage.flush() }
    }

    private func enqueueUsage(_ work: @escaping @Sendable (any UsageTracking) async -> Void) {
        let previous = pendingRecord
        let usage = self.usage
        pendingRecord = Task {
            await previous?.value
            await work(usage)
        }
    }

    /// Test seam: waits for everything queued so far to reach the tracker. There
    /// is no production caller — the chain is fire-and-forget by design.
    func drainPendingUsage() async {
        await pendingRecord?.value
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
            // The KIND only — the message names a file path and the underlying
            // store error, neither of which may leave the device.
            record(.launchFailed(kind: .cache))
            return
        }

        phase = .restoringAccount
        await restoreAccounts()
    }

    private func restoreAccounts() async {
        let accounts: [Account]
        do {
            accounts = try await auth.loadAccounts()
        } catch {
            logger.error("Account list unreadable: \(error.localizedDescription, privacy: .private)")
            phase = .failed(error.localizedDescription)
            record(.launchFailed(kind: .restore))
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
    /// - Parameter isAutomatic: whether this is Herald repairing an account by
    ///   itself. Its failures stay off `signInError`, which belongs to the
    ///   onboarding sheet nobody opened.
    /// - Returns: whether the account came up.
    @discardableResult
    private func activate(_ account: Account, select: Bool = true, isAutomatic: Bool = false) async -> Bool {
        guard let store else { return false }
        do {
            let tokens = try await auth.tokenProvider(for: account)
            await install(
                account: account,
                api: HQBaseAPIClient(origin: account.origin, tokens: tokens),
                store: store,
                select: select,
                // The wake socket authenticates with the SAME provider as the
                // REST client, so one refresh serves both and the two can never
                // race each other into spending the rotating grant twice.
                wake: (channels: URLSessionMailEventChannels(origin: account.origin), tokens: tokens)
            )
            return true
        } catch {
            logger.error("Account activation failed: \(error.localizedDescription, privacy: .private)")
            // One unreachable account must not take the whole app down when
            // another one is working.
            if graphs.isEmpty {
                phase = .failed(error.localizedDescription)
                // Nothing came up at all: the launch failed, for a reason that is
                // neither the cache nor the account list.
                record(.launchFailed(kind: .other))
            } else if !isAutomatic {
                signInError = error.localizedDescription
            }
            return false
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
    /// - Parameter wake: how to open this account's `GET /events` socket, and the
    ///   provider that authenticates it. `nil` in tests (and on any account
    ///   brought up without one), which leaves the poll loop at its full cadence
    ///   — the socket is an accelerator, never a dependency.
    func install(
        account: Account,
        api: any MailAPIClient,
        store: MailStore,
        select: Bool = true,
        wake: (channels: any MailEventChannelOpening, tokens: any BearerTokenProvider)? = nil
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
            notifier: notifier,
            record: recordUsage
        )
        // The badge is the SUM across accounts, so any account's count changing
        // re-reads all of them rather than trusting the number it was handed.
        viewModel.unreadCountDidChange = { [weak self] _ in
            self?.applyDockBadge()
        }
        // One expiry event, one automatic attempt: the view-model fires this on
        // the TRANSITION into `.needsReauth`, and the policy decides from there.
        viewModel.reauthenticationRequired = { [weak self] id in
            Task { await self?.attemptAutomaticReauthentication(accountID: id) }
        }
        // Built here, not in `activate`, because every one of its callbacks
        // points back at the engine and the view-model that were just created.
        let socket = wake.map { wake in
            MailEventSocket(
                channels: wake.channels,
                tokens: wake.tokens,
                // Awaited, never fired into a detached `Task`: two unordered
                // tasks can deliver a connected/disconnected pair BACKWARDS, and
                // the engine's flag is a latch — it would then hold the poll at
                // the stretched interval behind a socket that is already dead.
                healthChanged: { [weak engine] connected in
                    await engine?.setWakeSocketConnected(connected)
                },
                reauthenticationRequired: { [weak viewModel] in
                    await MainActor.run { viewModel?.wakeSocketRequiresReauthentication() }
                },
                signal: { [weak viewModel] signal in
                    await viewModel?.handleWakeSignal(signal)
                }
            )
        }
        viewModel.wake = socket
        let graph = AccountGraph(
            account: account,
            sync: engine,
            mail: viewModel,
            outbox: OutboxService(api: api),
            notifier: notifier,
            wake: socket
        )
        // Published synchronously, so no second install can slip in and be
        // forgotten.
        let superseded = graphs.updateValue(graph, forKey: account.id)
        if !accountIDs.contains(account.id) { accountIDs.append(account.id) }
        // Selecting is what puts this account in the window. A restore bringing
        // the OTHER accounts up must not steal it — but an empty window beats
        // nothing, so a live graph is selected when none is showing.
        // Not a "switch": this is an account arriving, which `account_added` (or a
        // launch restore) already accounts for.
        if select || selectedGraph == nil { selectAccount(account.id) }
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
        await viewModel.setActive(isApplicationActive())
        // Re-checked because starting a graph that has already been superseded
        // is exactly how an unowned polling loop is born.
        guard isCurrent(graph) else { return await graph.stop() }
        await engine.start(accountID: account.id)
        // A banner clicked before THIS account was up (the click that launched
        // Herald) is replayed now that its graph can answer.
        if let route = pendingRoute, route.accountID == account.id {
            pendingRoute = nil
            await open(route, isLaunchReplay: true)
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
    /// - Parameter isLaunchReplay: whether this is the held route being replayed
    ///   as its account comes up, rather than a click on a live window. The
    ///   replay's account assignment is Herald finishing its own launch, not the
    ///   user reaching for the switcher, and must not be counted as a switch.
    func open(_ route: NewMailRoute, isLaunchReplay: Bool = false) async {
        // Clicking a banner can LAUNCH Herald — or name an account still coming
        // up behind the first one, since a restore activates the rest in the
        // background. Held until that account installs rather than dropped.
        guard let graph = graphs[route.accountID] else {
            pendingRoute = route
            return
        }
        // A clicked banner IS the user choosing an account, so this one counts —
        // unless it is the launch replay, which is not a choice made twice.
        if isLaunchReplay {
            selectAccount(route.accountID)
        } else {
            selectedAccountID = route.accountID
        }
        guard let threadID = route.threadID else { return }
        // The view the reveal lands on was reached from a notification.
        graph.mail.pendingNavigationSource = .notification
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
        record(.notificationsToggled(enabled: enabled))
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
        let accountID = session.accountID
        let model = ComposeViewModel(context: session.context, outbox: outbox, record: recordUsage, draftCache: { [weak self] event in
            // Routed to the account the composer was OPENED from — the same one
            // whose `outbox` is saving the draft — never to whichever account the
            // window happens to be showing: switching accounts with a composer up
            // would otherwise file the draft in the wrong account's folder.
            // Looked up fresh each time, because a composer can outlive its graph
            // (sign-out with a window open), and the event then belongs to nobody.
            guard let mail = self?.graphs[accountID]?.mail else { return }
            Task { await mail.applyDraftCacheEvent(event) }
        })
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
        // Herald coming to the front is the moment a deferred automatic re-auth
        // becomes allowed: the session almost always dies while the user is
        // somewhere else, and the sync pass that noticed announced it once.
        if active { await retryAutomaticReauthentication() }
    }

    // MARK: - Activation

    /// Sync cadence follows the APPLICATION's activation, not a window's
    /// `scenePhase`. Per-window scenePhase flaps: opening a compose window moves
    /// the key window off the mail window, the mail scene reports inactive, and
    /// the engine backs off to the idle cadence while the user is plainly using
    /// the app.
    /// Internal, not private, so a test can drive activation without `start()`
    /// opening the real store.
    func observeActivation() {
        activityTask?.cancel()
        activityTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @Sendable [weak self] in
                    let active = NotificationCenter.default.notifications(
                        named: NSApplication.didBecomeActiveNotification
                    )
                    for await _ in active {
                        // On the record chain, so the session opens ahead of the
                        // events the user is about to generate inside it.
                        await self?.recordApplicationDidBecomeActive()
                        await self?.setWindowActive(true)
                    }
                }
                group.addTask { @Sendable [weak self] in
                    let resigned = NotificationCenter.default.notifications(
                        named: NSApplication.didResignActiveNotification
                    )
                    for await _ in resigned {
                        // Queued BEHIND everything already recorded, so a flush
                        // never overtakes the events it exists to push.
                        await self?.recordFlush()
                        await self?.setWindowActive(false)
                    }
                }
            }
        }
    }
}
