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
            accounts = try auth.accounts()
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
                select: select
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

    func signIn(originText: String) async {
        let result = await performSignIn(originText: originText)
        record(.accountAdded(outcome: result.outcome, kind: result.kind))
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
    /// - Parameter isAutomatic: whether Herald started this round trip by itself.
    ///   An automatic attempt leaves `isSigningIn`, `signInError` and
    ///   `presentsAddAccount` alone: nothing asked for the onboarding sheet, and
    ///   a failure must land on the re-auth banner that is already up rather than
    ///   raising sheet state over the mail the user is reading.
    private func performSignIn(
        originText: String,
        isAutomatic: Bool = false
    ) async -> SignInResult {
        guard let origin = Self.normalizedOrigin(from: originText) else {
            if !isAutomatic {
                signInError = "Enter the https address of your HQBase server, for example https://mail.example.com"
            }
            // A typo in the address field, not an OAuth fault: there is no kind
            // to report, and the text the user typed is never one.
            return SignInResult(outcome: .failed)
        }
        if !isAutomatic {
            isSigningIn = true
            signInError = nil
        }
        defer { if !isAutomatic { isSigningIn = false } }
        do {
            let account = try await auth.addAccount(origin: origin)
            if !isAutomatic { presentsAddAccount = false }
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
            if !isAutomatic { signInError = error.localizedDescription }
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
        let succeeded = await runReauthentication(account: account, isAutomatic: false)
        autoReauth.finish(accountID: accountID, succeeded: succeeded)
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
            return await self.runReauthentication(account: account, isAutomatic: true)
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
    private func runReauthentication(account: Account, isAutomatic: Bool) async -> Bool {
        let accountID = account.id
        let result = await performSignIn(
            originText: account.origin.absoluteString,
            isAutomatic: isAutomatic
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
        guard let account = graphs[accountID]?.account
            ?? (try? auth.accounts())?.first(where: { $0.id == accountID })
        else { return }
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
