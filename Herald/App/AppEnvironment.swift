import AppKit
import Foundation
import HeraldKit
import OSLog
import SwiftData

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "AppEnvironment")

/// The composition root: opens the cache, restores every signed-in account and
/// wires Keychain → auth → API client → sync + actions → view-model per account.
///
/// Nothing here blocks `App.init`: the container is opened on a detached task and
/// the UI shows the real milestone it is waiting on.
///
/// Split across three files. This one owns the type, its state and the account
/// lifecycle (launch, activate, install, stop); `AppEnvironment+SignIn.swift` owns
/// onboarding, re-authentication and sign-out; `AppEnvironment+Compose.swift` owns
/// the compose sessions. A Swift extension cannot hold stored properties, so the
/// state the other two files read and write lives here — and is `internal` rather
/// than `private` for exactly that reason, not because anything outside
/// ``AppEnvironment`` is meant to touch it.
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

    // These four were `private(set)`. They lost it to the file split and nothing
    // else: `private` is FILE scope, and `AppEnvironment+SignIn.swift` is where
    // the sign-in state is now driven from. They remain write-only-from-
    // ``AppEnvironment`` by convention — views read them, and a view that
    // assigned one would be a bug the compiler no longer catches.
    var phase: Phase = .openingCache
    /// Set while the onboarding sheet is running a sign-in.
    var isSigningIn = false
    /// The step the visible sign-in is on; `nil` when none is running. Only ever
    /// set by an INTERACTIVE sign-in — an automatic re-auth is silent by design.
    var signInStage: SignInStage?
    var signInError: String?
    /// Drives the "Add Account…" sheet over the mail UI.
    var presentsAddAccount = false

    /// Every signed-in account's live graph, keyed by account id.
    private(set) var graphs: [Account.ID: AccountGraph] = [:]
    /// Presentation order of ``graphs`` — a dictionary has none, and the account
    /// switcher must not reshuffle itself on every keystroke. Not `private(set)`
    /// for the same reason as ``phase`` above: sign-out, which removes an entry,
    /// lives in `AppEnvironment+SignIn.swift`.
    var accountIDs: [Account.ID] = []

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
    func selectAccount(_ id: Account.ID?) {
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
    struct ComposeSession {
        let accountID: Account.ID
        let context: ComposeContext
        /// The live composer. Owned here so the window's `.task(id:)` — which
        /// re-runs whenever SwiftUI rebuilds the scene root — finds the SAME
        /// instance, with whatever the user has typed into it, instead of
        /// building a second one over a half-written message.
        var model: ComposeViewModel?
    }

    var composeSessions: [ComposeRequest.ID: ComposeSession] = [:]
    /// Watches app-level activation to drive the sync cadence.
    private var activityTask: Task<Void, Never>?

    let auth: AuthCoordinator
    private let defaults: UserDefaults
    /// Whether Herald is the frontmost app. Injected so a test can drive the
    /// automatic re-auth gate without an `NSApplication` it cannot activate.
    let isApplicationActive: @MainActor @Sendable () -> Bool
    /// The rules for re-running consent by ourselves. Observed (not
    /// `@ObservationIgnored`): the banner renders its "signing you back in…"
    /// state straight off it.
    var autoReauth = AutoReauthPolicy()
    /// The live automatic attempts, so a sign-out can cancel one instead of
    /// letting its `install` resurrect the account behind it. Observation-ignored:
    /// the banner reads ``autoReauth``, not this.
    @ObservationIgnored var automaticReauthTasks: [Account.ID: Task<Bool, Never>] = [:]
    /// Cancels the live INTERACTIVE sign-in. Held as a closure rather than the
    /// task itself only because the two entry points (first sign-in, re-auth)
    /// return different values; what matters is that the handle is kept at all —
    /// discarding it is what made the reported hang unrecoverable.
    @ObservationIgnored var signInCancellation: (@Sendable () -> Void)?
    /// Bumped by every cancel and every new interactive attempt. An attempt only
    /// owns the sign-in UI — and is only allowed to install its account — while
    /// its generation is still the current one, so a session that completes after
    /// the user gave up cannot reach back and change the screen under them.
    @ObservationIgnored var signInGeneration = 0
    /// The account a live INTERACTIVE re-auth is repairing, if any. Held so a
    /// cancel (or a sign-out) can release that account's ``AutoReauthPolicy``
    /// claim without waiting for a task that may never return.
    @ObservationIgnored var signInReauthAccountID: Account.ID?
    /// The one usage-analytics seam for the whole app. Default ``NoopUsageTracker``,
    /// so every test — and any caller that does not opt in — collects nothing.
    let usage: any UsageTracking
    /// The tail of the record chain. Every emission awaits the previous one, so
    /// events reach the SDK in the order they happened rather than in whatever
    /// order a pile of unstructured tasks got scheduled.
    @ObservationIgnored private var pendingRecord: Task<Void, Never>?
    private var container: ModelContainer?
    var store: MailStore?

    /// The launch restore's background activation of the accounts queued behind
    /// the first one. RETAINED: unowned, a sign-out landing while this loop was
    /// awaiting a slower account's discovery round trip could not be seen by it,
    /// and the purged account was activated — and re-installed with a live engine
    /// — behind the removal (audit C10).
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    /// The accounts that restore has still to bring up. Membership is the loop's
    /// permission slip: ``cancelPendingRestore(accountID:)`` removes an account
    /// the moment it is signed out, which is how the loop learns both to skip it
    /// and — when the removal lands mid-activation — to undo the install.
    @ObservationIgnored private var pendingRestoreIDs: Set<Account.ID> = []

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

    // MARK: - Signature management

    /// Settings ▸ Signatures, one per account, built on first use.
    ///
    /// Held HERE rather than made in the view's `body`: a fresh model per
    /// SwiftUI pass would re-list on every redraw, and `@State` would pin
    /// whichever instance happened to be first anyway. Cleared with the account
    /// in ``forgetSignatureSettings(accountID:)``.
    @ObservationIgnored private var signatureSettingsModels: [Account.ID: SignatureSettingsModel] = [:]

    /// Bumped after any signature mutation. Open compose windows key their
    /// candidate fetch on it, so a signature renamed or deleted in Settings is
    /// not still offered under its old name by a composer that is already up.
    private(set) var signatureRevision = 0

    /// The selected account's pane model, or `nil` when no account is up (the
    /// tab is then not shown at all rather than showing an empty list).
    func signatureSettingsModel() -> SignatureSettingsModel? {
        guard let id = selectedAccountID, let graph = graphs[id] else { return nil }
        if let existing = signatureSettingsModels[id] { return existing }
        let model = SignatureSettingsModel(
            service: graph.signatures,
            // Read through the view-model on every load, so a mailbox that has
            // synced since the pane opened is offered as a scope.
            mailboxes: { [weak graph] in graph?.mail.mailboxes ?? [] },
            didMutate: { [weak self] in self?.signatureRevision += 1 },
            // The GRANTED scopes (the server echoes them on the token response),
            // re-read on every load so a re-auth that widened or refused the
            // grant is seen: this is what lets the pane stop offering "Sign In
            // Again" once the server has demonstrably not granted the scope.
            grantedScopes: { [weak graph] in graph?.account.scopes ?? [] }
        )
        signatureSettingsModels[id] = model
        return model
    }

    /// Drops one account's pane model — on sign-out, and on a re-auth that
    /// replaces the graph, so the pane cannot keep talking to a dead client.
    func forgetSignatureSettings(accountID: Account.ID) {
        signatureSettingsModels[accountID] = nil
    }

    /// The Signatures pane's "Sign In Again" button.
    func reauthenticateSelectedAccount() {
        let accountID = selectedAccountID
        Task { await reauthenticate(accountID: accountID) }
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

    /// Internal, not private, so a test can drive a restore without `start()`
    /// opening the real store — the same seam ``install(account:api:store:)`` and
    /// ``observeActivation()`` already offer. Assign ``store`` first.
    func restoreAccounts() async {
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
        restoreTask?.cancel()
        pendingRestoreIDs = Set(rest.map(\.id))
        restoreTask = Task { [weak self] in
            for account in rest {
                guard !Task.isCancelled, let self else { return }
                // Checked BEFORE activating: the accounts are brought up one at a
                // time, so an account near the back of the queue can be signed
                // out — banner, menu or Settings — while a slow or unreachable
                // server ahead of it is still being contacted. Activating it then
                // would re-install an account the user has already removed.
                guard self.pendingRestoreIDs.contains(account.id) else { continue }
                await self.activate(account, select: false)
                // Re-checked AFTER the await, because the sign-out can just as
                // easily land while THIS account is the one activating: `install`
                // has then published a graph behind the removal, and it has to
                // come straight back out.
                if self.pendingRestoreIDs.remove(account.id) == nil {
                    await self.stopGraph(accountID: account.id)
                }
            }
            self?.pendingRestoreIDs.removeAll()
        }
    }

    /// Drops one account from the launch restore's queue, so the restore loop
    /// neither activates it nor keeps an install that raced the removal — and
    /// stops the restore outright once it has nothing left to bring up.
    ///
    /// Only the queue is cancelled, never the accounts still waiting behind it:
    /// signing one account out must not leave the others stranded on the launch
    /// placeholder.
    func cancelPendingRestore(accountID: Account.ID) {
        pendingRestoreIDs.remove(accountID)
        guard pendingRestoreIDs.isEmpty else { return }
        restoreTask?.cancel()
        restoreTask = nil
    }

    /// The accounts the launch restore has still to bring up. Test seam: the
    /// queue is otherwise only observable by which graphs eventually appear.
    var pendingRestoreAccountIDs: Set<Account.ID> { pendingRestoreIDs }

    /// Test seam: waits for the launch restore to finish bringing up the
    /// accounts queued behind the first one. No production caller — the restore
    /// runs behind the live window by design.
    func drainPendingRestore() async {
        await restoreTask?.value
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
    func activate(_ account: Account, select: Bool = true, isAutomatic: Bool = false) async -> Bool {
        guard let store else { return false }
        do {
            let tokens = try await auth.tokenProvider(for: account)
            await install(
                account: account,
                // `includeLabels: true` asks every label-capable route to embed
                // the message's own labels (upstream 1.4.2+). A server older than
                // that IGNORES the parameter and answers without the key, which
                // arrives as `MessageSummary.labels == nil` — "said nothing" — and
                // leaves the per-label sweep as the membership source. So this is
                // safe to send unconditionally and Herald never probes a version.
                api: HQBaseAPIClient(origin: account.origin, tokens: tokens, includeLabels: true),
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
                // A plain `await` on the isolated method, not `MainActor.run`:
                // `MailViewModel` is `@MainActor`, so the hop is the call.
                reauthenticationRequired: { [weak viewModel] in
                    await viewModel?.wakeSocketRequiresReauthentication()
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
            signatures: SignatureManagementService(api: api),
            notifier: notifier,
            wake: socket
        )
        // Published synchronously, so no second install can slip in and be
        // forgotten.
        let superseded = graphs.updateValue(graph, forKey: account.id)
        // The Settings pane holds the SUPERSEDED graph's service; a re-auth must
        // not leave it talking to a client whose tokens are gone.
        forgetSignatureSettings(accountID: account.id)
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
    func isCurrent(_ graph: AccountGraph) -> Bool {
        graphs[graph.account.id] === graph
    }

    /// Stops and drops one account's graph, leaving the others alone. The
    /// account keeps its place in ``accountIDs`` so a re-install (re-auth) does
    /// not shuffle the switcher.
    func stopGraph(accountID: Account.ID) async {
        // Before the `graphs` guard: an account the restore has QUEUED but not
        // yet activated has no graph to remove, and leaving it in the queue is
        // precisely how it would come back.
        cancelPendingRestore(accountID: accountID)
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
