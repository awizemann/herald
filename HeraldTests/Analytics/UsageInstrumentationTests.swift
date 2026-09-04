import AppKit
import Foundation
import HeraldKit
import Testing
@testable import Herald

/// Collects what the app tried to send, without an SDK behind it.
///
/// An actor, because ``UsageTracking`` is a `nonisolated protocol` and the whole
/// point of the record chain is that emission happens off the call site — a
/// main-actor spy would hide exactly the ordering bug these tests exist to catch.
actor RecordingUsageTracker: UsageTracking {
    private(set) var events: [UsageEvent] = []
    private(set) var activationCount = 0
    private(set) var flushCount = 0

    func track(_ event: UsageEvent) async { events.append(event) }
    func applicationDidBecomeActive() async { activationCount += 1 }
    func flush() async { flushCount += 1 }
    /// Records every opt-out write AND applies it, so a caller that re-reads
    /// `isEnabled` after writing (as the Settings toggle does) sees its own effect.
    func setEnabled(_ enabled: Bool) async {
        enabledWrites.append(enabled)
        isEnabled = enabled
    }

    private(set) var enabledWrites: [Bool] = []
    private(set) var isEnabled = true
    /// `nonisolated(unsafe)` because the protocol requirement is synchronous —
    /// tests only ever flip this before other calls are in flight, so there is
    /// no real race to guard against.
    nonisolated(unsafe) var isAvailable = true

    /// Test-only: simulates the no-write-key build the toggle disables for.
    func makeUnavailable() {
        isAvailable = false
    }

    var names: [String] { events.map(\.name) }

    /// Polls until at least `count` events have arrived, or the deadline passes.
    /// Never sleeps longer than it has to, and never asserts on a race: a caller
    /// that wants "exactly N" waits for an N+1th sentinel instead.
    @discardableResult
    func drain(until count: Int, deadline: Duration = .seconds(2)) async -> [UsageEvent] {
        let end = ContinuousClock.now.advanced(by: deadline)
        while events.count < count, ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return events
    }
}

/// One view-model wired to a real ``AppEnvironment`` record chain — the same
/// ordering guarantee production gets, rather than a hand-rolled substitute.
@MainActor
private struct UsageHarness {
    let store: MailStore
    let api: FakeMailAPIClient
    let environment: AppEnvironment
    let tracker: RecordingUsageTracker
    let model: MailViewModel
    let events: AsyncStream<SyncEvent>.Continuation

    static func make() async throws -> UsageHarness {
        let store = try MailStore.inMemory()
        let api = FakeMailAPIClient()
        let tracker = RecordingUsageTracker()
        let environment = AppEnvironment(defaults: scratchDefaults(), usage: tracker)
        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .unbounded)
        let model = MailViewModel(
            accountID: "acct",
            accountLabel: "Test",
            api: api,
            store: store,
            actions: MailActionService(api: api, store: store),
            events: stream,
            markReadDelay: .seconds(3600),
            record: environment.recordUsage
        )
        return UsageHarness(
            store: store, api: api, environment: environment,
            tracker: tracker, model: model, events: continuation
        )
    }

    /// Everything queued so far has reached the tracker.
    func settle() async { await environment.drainPendingUsage() }

    func recorded() async -> [UsageEvent] {
        await settle()
        return await tracker.events
    }

    static func scratchDefaults() -> UserDefaults {
        let suite = "UsageInstrumentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

@MainActor
@Suite struct UsageRecordChainTests {

    /// The chain exists so events arrive in the order they happened. Fails if
    /// `record` ever forks an independent task per event — which reorders under
    /// any real scheduler and is invisible in a single-event test.
    @Test func recordsAreDeliveredInCallOrder() async {
        let tracker = RecordingUsageTracker()
        let environment = AppEnvironment(
            defaults: UsageHarness.scratchDefaults(), usage: tracker
        )
        // Interleaved with awaits, i.e. with real scheduling opportunities
        // between the calls, which is where an unordered implementation loses.
        for index in 0..<50 {
            environment.record(.searchRun(scope: .local, results: UsageBucket(count: index)))
            if index % 7 == 0 { await Task.yield() }
        }
        await environment.drainPendingUsage()

        let expected = (0..<50).map { UsageBucket(count: $0).rawValue }
        let received = await tracker.events.map { $0.props["results"] }
        #expect(received == expected.map { UsageValue.string($0) })
    }

    /// The lifecycle hooks the SDK needs: swift-stats installs no AppKit
    /// observers of its own. Fails if activation stops driving `app_open` /
    /// sessions, or if resigning active no longer pushes the queue — the state
    /// in which a quit loses everything the session recorded.
    @Test func activationDrivesTheSessionAndResigningFlushes() async throws {
        let tracker = RecordingUsageTracker()
        let environment = AppEnvironment(
            defaults: UsageHarness.scratchDefaults(), usage: tracker
        )
        environment.observeActivation()

        // The observer subscribes on a task of its own, so the first post can
        // legitimately land before it is listening; posting until it is heard
        // is the only race-free way to drive a NotificationCenter stream.
        try await postUntil("the activation observer to be listening") {
            NotificationCenter.default.post(
                name: NSApplication.didBecomeActiveNotification, object: nil
            )
            await environment.drainPendingUsage()
            return await tracker.activationCount >= 1
        }
        #expect(await tracker.flushCount == 0, "becoming active must not flush")

        try await postUntil("the resign observer to be listening") {
            NotificationCenter.default.post(
                name: NSApplication.didResignActiveNotification, object: nil
            )
            await environment.drainPendingUsage()
            return await tracker.flushCount >= 1
        }
    }

    private func postUntil(
        _ description: Comment,
        timeout: Duration = .seconds(2),
        _ attempt: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await attempt() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting: \(description)")
    }
}

@MainActor
@Suite struct UsageViewShownTests {

    /// `selection` is assigned in `init`, where a `didSet` never fires, so the
    /// folder the window comes up on has to be said out loud. Fails if the launch
    /// view is missing, is attributed to anything but `launch`, or is emitted
    /// twice — the sentinel is what makes "exactly once" assertable.
    @Test func theLaunchViewIsRecordedOnceWithVialaunch() async throws {
        let harness = try await UsageHarness.make()
        await harness.model.start()
        // Trailing sentinel: anything the launch path emitted late is already
        // behind this event by the time it appears.
        harness.model.record(.remoteMediaLoaded)

        let events = await harness.recorded()
        #expect(events.first == .viewShown(view: .inbox, via: .launch))
        #expect(events.filter { $0.name == "view_shown" }.count == 1)
        #expect(events.last == .remoteMediaLoaded)
    }

    /// The sidebar restores the last mailbox scope on a task of its own, which can
    /// run either side of `start()`. Both orders must produce exactly ONE launch
    /// view: fails if the restore assigns `selection` itself (a second
    /// `view_shown`, which is what a raw `pendingNavigationSource = .launch` plus
    /// an assignment does), or if the restore-first order loses the launch view
    /// entirely because `start()` then thinks it has nothing to say.
    @Test(arguments: [true, false])
    func theLaunchViewIsRecordedOnceAcrossTheSidebarRestore(startsFirst: Bool) async throws {
        let harness = try await UsageHarness.make()
        let restored = MailViewModel.FolderSelection(mailboxID: "mbA", folder: .inbox)

        if startsFirst {
            await harness.model.start()
            harness.model.restoreSelection(restored)
        } else {
            harness.model.restoreSelection(restored)
            await harness.model.start()
        }
        harness.model.record(.remoteMediaLoaded)  // sentinel

        let events = await harness.recorded()
        let views = events.filter { $0.name == "view_shown" }
        #expect(views == [.viewShown(view: .inbox, via: .launch)])
        #expect(harness.model.selection == restored, "the restore must still apply")
        #expect(events.last == .remoteMediaLoaded)
    }

    /// A restore that is not part of the launch at all (the scope it wants is
    /// already showing) must stay silent AND must not leave a `.launch` source
    /// behind for the user's next click to wear.
    @Test func aNoOpRestoreReportsNothingAndLeavesNoSource() async throws {
        let harness = try await UsageHarness.make()
        await harness.model.start()

        harness.model.restoreSelection(harness.model.selection)
        harness.model.selection = .init(mailboxID: nil, folder: .trash)

        let views = await harness.recorded().filter { $0.name == "view_shown" }
        #expect(views == [
            .viewShown(view: .inbox, via: .launch),
            .viewShown(view: .trash, via: .other),
        ])
    }

    /// Fails if a no-op assignment (SwiftUI re-writing a `List` selection binding
    /// with the value it already has, which it does constantly) emits a view.
    @Test func aRealFolderChangeRecordsOnceAndASameValueSetRecordsNothing() async throws {
        let harness = try await UsageHarness.make()
        await harness.model.start()

        harness.model.pendingNavigationSource = .sidebar
        harness.model.selection = .init(mailboxID: nil, folder: .archived)
        harness.model.selection = .init(mailboxID: nil, folder: .archived)
        harness.model.record(.remoteMediaLoaded)

        let views = await harness.recorded().filter { $0.name == "view_shown" }
        #expect(views == [
            .viewShown(view: .inbox, via: .launch),
            .viewShown(view: .archived, via: .sidebar),
        ])
    }

    /// The `via` is consumed even when the navigation turns out to be a no-op.
    /// Fails if a stale source survives: the click that did nothing would then
    /// label the NEXT navigation, which is the one bug a "set it before you
    /// navigate" protocol invites.
    @Test func aNoOpNavigationConsumesThePendingSource() async throws {
        let harness = try await UsageHarness.make()
        await harness.model.start()

        // A sidebar click on the folder that is already showing: nothing changes.
        harness.model.pendingNavigationSource = .sidebar
        harness.model.selection = .init(mailboxID: nil, folder: .inbox)
        // …and now a navigation that says nothing about where it came from.
        harness.model.selection = .init(mailboxID: nil, folder: .trash)

        let views = await harness.recorded().filter { $0.name == "view_shown" }
        #expect(views.last == .viewShown(view: .trash, via: .other), "a stale `via` leaked")
    }

    /// Drafts is the other half of the middle column. Fails if entering it is
    /// silent, or if leaving it for the folder underneath reports nothing —
    /// which is what a `selection`-only implementation does, because the
    /// selection never changes.
    @Test func enteringAndLeavingDraftsBothReportAView() async throws {
        let harness = try await UsageHarness.make()
        await harness.model.start()

        harness.model.sidebarItem = .drafts
        harness.model.sidebarItem = .folder(.init(mailboxID: nil, folder: .inbox))

        let views = await harness.recorded().filter { $0.name == "view_shown" }
        #expect(views == [
            .viewShown(view: .inbox, via: .launch),
            .viewShown(view: .drafts, via: .sidebar),
            .viewShown(view: .inbox, via: .sidebar),
        ])
    }

    /// Leaving Drafts for a DIFFERENT folder is one navigation, to the folder the
    /// user picked. Fails if the folder being LEFT is reported on the way out — a
    /// phantom view nobody saw, ahead of the real one — which is what reporting
    /// from `showDrafts(false)` does, since it reads `selection` before the
    /// selection has moved.
    @Test func leavingDraftsForAnotherFolderReportsOnlyTheDestination() async throws {
        let harness = try await UsageHarness.make()
        await harness.model.start()

        harness.model.sidebarItem = .drafts
        harness.model.sidebarItem = .folder(.init(mailboxID: nil, folder: .trash))
        harness.model.record(.remoteMediaLoaded)  // sentinel: nothing landed late

        let events = await harness.recorded()
        let views = events.filter { $0.name == "view_shown" }
        #expect(views == [
            .viewShown(view: .inbox, via: .launch),
            .viewShown(view: .drafts, via: .sidebar),
            .viewShown(view: .trash, via: .sidebar),
        ])
        #expect(events.last == .remoteMediaLoaded)
    }

    /// ⌘[ / ⎋ / ⏎ are a different way of getting somewhere than a click, and the
    /// vocabulary has a word for it. Fails if the keyboard paths go back to
    /// reporting `other`, which made `shortcut` unreachable in the whole app.
    @Test func keyboardNavigationIsAttributedToTheShortcut() async throws {
        let harness = try await UsageHarness.make()
        let message = MailFixtures.message(id: "m1", threadID: "t1", mailboxID: "mbA")
        let second = MailFixtures.message(id: "m2", threadID: "t1", mailboxID: "mbA")
        try await harness.store.upsertMessages([message, second], accountID: "acct")
        try await harness.store.upsertConversations(
            [MailFixtures.conversation(second, messageCount: 2)],
            accountID: "acct", mailboxID: nil, folder: .inbox
        )
        await harness.model.start()
        harness.model.select("t1", drill: false)

        harness.model.openSelectedThreadViaShortcut()
        harness.model.exitThreadViaShortcut()
        // The source must not survive the step it labelled.
        harness.model.selection = .init(mailboxID: nil, folder: .trash)

        let views = await harness.recorded().filter { $0.name == "view_shown" }
        #expect(views == [
            .viewShown(view: .inbox, via: .launch),
            .viewShown(view: .thread, via: .shortcut),
            .viewShown(view: .inbox, via: .shortcut),
            .viewShown(view: .trash, via: .other),
        ])
    }
}

@MainActor
@Suite struct UsageSearchTests {

    /// A search is what the user COMMITTED, not what the debounce pushed. Fails if
    /// the local emission goes back into `searchQuery.didSet`, where typing one
    /// word arrives as a search per keystroke and inflates the count several-fold.
    @Test func theLocalSearchIsReportedOnSubmitAndNotOnEveryKeystroke() async throws {
        let harness = try await UsageHarness.make()
        await harness.model.start()

        // Below `minimumServerSearchLength`, so nothing here can reach the server
        // and the only `search_run` that may appear is the local one.
        harness.model.searchQuery = "z"
        harness.model.searchQuery = "y"  // a second keystroke, still one letter
        harness.model.record(.remoteMediaLoaded)  // sentinel
        var runs = await harness.recorded().filter { $0.name == "search_run" }
        #expect(runs.isEmpty, "typing is not searching")

        harness.model.submitSearch()
        harness.model.record(.remoteMediaLoaded)  // sentinel
        runs = await harness.recorded().filter { $0.name == "search_run" }
        #expect(runs == [.searchRun(scope: .local, results: .zero)])

        // Clearing the field is not a search either.
        harness.model.searchQuery = ""
        harness.model.submitSearch()
        harness.model.record(.remoteMediaLoaded)
        runs = await harness.recorded().filter { $0.name == "search_run" }
        #expect(runs.count == 1, "an empty needle is not a search")
    }
}

@MainActor
@Suite struct UsageActionAndSyncTests {

    /// The menu-bar verbs act on "the selection", which is a different scope from
    /// clicking a row — and the count is a bucket, never a number. Fails if the
    /// scope collapses to `conversation`, or if an exact count is ever attached.
    @Test func actingOnTheSelectionReportsTheSelectionScopeAndABucketedCount() async throws {
        let harness = try await UsageHarness.make()
        let message = MailFixtures.message(id: "m1", threadID: "t1", mailboxID: "mbA")
        try await harness.store.upsertMessages([message], accountID: "acct")
        try await harness.store.upsertConversations(
            [MailFixtures.conversation(message)], accountID: "acct", mailboxID: nil, folder: .inbox
        )
        await harness.model.start()
        harness.model.select("t1", drill: false)

        await harness.model.performOnSelection(.archive)

        let performed = await harness.recorded().filter { $0.name == "message_action_performed" }
        #expect(performed == [
            .messageActionPerformed(action: .archive, scope: .selection, count: .one)
        ])
        for event in performed {
            #expect(event.props["count"] == .string("1"), "counts are only ever bucketed")
        }
    }

    /// The trigger is derived, because ``SyncEvent`` carries none: the first pass
    /// is the launch, an explicit refresh claims the next completion, and
    /// everything after that is the cadence. Fails if a post-action refresh, or
    /// the poll, is ever reported as something the user asked for.
    @Test func syncCompletionsAreAttributedToLaunchThenManualThenAuto() async throws {
        let harness = try await UsageHarness.make()
        await harness.model.start()

        // One pass at a time, each awaited before the next is provoked: the
        // events are consumed on a task of their own, so firing all three at
        // once would be asserting on the interleaving rather than on the rule.
        harness.events.yield(.began)
        harness.events.yield(.finished)
        await harness.tracker.drain(until: 2)  // launch view + first completion

        await harness.model.refresh()
        harness.events.yield(.began)
        harness.events.yield(.changed(ChangeSet(updated: ["m1"])))
        harness.events.yield(.finished)
        await harness.tracker.drain(until: 3)

        harness.events.yield(.began)
        harness.events.yield(.finished)
        await harness.tracker.drain(until: 4)
        await harness.settle()
        let syncs = await harness.tracker.events.filter { $0.name == "sync_completed" }
        #expect(syncs == [
            .syncCompleted(trigger: .launch, changed: false),
            .syncCompleted(trigger: .manual, changed: true),
            .syncCompleted(trigger: .auto, changed: false),
        ])
    }

    /// Fails if a failed pass reports an error message, or invents a kind for an
    /// error the vocabulary does not cover.
    @Test func aFailedPassReportsOnlyItsKindAndTrigger() async throws {
        let harness = try await UsageHarness.make()
        await harness.model.start()

        harness.events.yield(.began)
        harness.events.yield(.failed(MailAPIError.cursorExpired))
        await harness.tracker.drain(until: 2)
        await harness.settle()

        let failures = await harness.tracker.events.filter { $0.name == "sync_failed" }
        #expect(failures == [.syncFailed(kind: .cursorExpired, trigger: .launch)])
        #expect(failures.first?.props.keys.sorted() == ["kind", "trigger"])
    }
}

@MainActor
@Suite struct UsageAccountTests {

    /// A launch restore assigns the selected account too, and it is not the user
    /// switching accounts. Fails if bringing accounts up — or falling back after
    /// a sign-out — is counted as a switch, which would drown the real signal.
    @Test func accountSwitchedIsOnlyRecordedWhenTheUserPicksAnAccount() async throws {
        let tracker = RecordingUsageTracker()
        let environment = AppEnvironment(
            defaults: UsageHarness.scratchDefaults(), usage: tracker
        )
        let store = try MailStore.inMemory()
        let a = Account(origin: URL(string: "https://a.example.com")!, clientID: "cid", scopes: [])
        let b = Account(origin: URL(string: "https://b.example.com")!, clientID: "cid", scopes: [])

        // The restore shape: both accounts come up behind the window.
        await environment.install(account: a, api: FakeMailAPIClient(), store: store, select: false)
        await environment.install(account: b, api: FakeMailAPIClient(), store: store, select: false)
        await environment.drainPendingUsage()
        #expect(
            await tracker.names.contains("account_switched") == false,
            "a restore is not a switch"
        )

        // Now the user picks the other account in the switcher.
        environment.selectedAccountID = b.id
        await environment.drainPendingUsage()
        let switches = await tracker.events.filter { $0.name == "account_switched" }
        #expect(switches == [.accountSwitched(accounts: .twoToFive)])
    }

    /// Clicking a banner can LAUNCH Herald: the route is held until its account
    /// comes up and then replayed. The replay assigns the selected account, but
    /// nobody reached for the switcher — fails if that assignment is counted as a
    /// switch (every notification-launched session would report one), while a
    /// click on a live window still is one.
    @Test func aLaunchTimeRouteReplayIsNotAnAccountSwitch() async throws {
        let tracker = RecordingUsageTracker()
        let environment = AppEnvironment(
            defaults: UsageHarness.scratchDefaults(), usage: tracker
        )
        let store = try MailStore.inMemory()
        let a = Account(origin: URL(string: "https://a.example.com")!, clientID: "cid", scopes: [])
        let b = Account(origin: URL(string: "https://b.example.com")!, clientID: "cid", scopes: [])
        await environment.install(account: a, api: FakeMailAPIClient(), store: store)

        // The banner names an account that is not up yet: held, then replayed by
        // `install`. No thread id, so nothing is revealed — the account
        // assignment is the whole point here.
        await environment.open(NewMailRoute(accountID: b.id, threadID: nil, messageID: nil))
        await environment.install(account: b, api: FakeMailAPIClient(), store: store, select: false)
        await environment.drainPendingUsage()
        #expect(environment.selectedAccountID == b.id, "the replay must still switch the window")
        #expect(
            await tracker.names.contains("account_switched") == false,
            "a launch-time replay is not a switch"
        )

        // The same route on a live window IS the user choosing an account.
        await environment.open(NewMailRoute(accountID: a.id, threadID: nil, messageID: nil))
        await environment.drainPendingUsage()
        let switches = await tracker.events.filter { $0.name == "account_switched" }
        #expect(switches == [.accountSwitched(accounts: .twoToFive)])
    }

    /// Signing an account out is reported, and reported without naming it. Fails
    /// if the origin, the label or the id ever becomes a prop.
    @Test func signingOutReportsARemovalWithNoProps() async throws {
        let tracker = RecordingUsageTracker()
        let a = Account(origin: URL(string: "https://a.example.com")!, clientID: "cid", scopes: [])
        let environment = AppEnvironment(
            auth: AuthCoordinator(store: InMemoryAccountStore(accounts: [a])),
            defaults: UsageHarness.scratchDefaults(),
            usage: tracker
        )
        await environment.install(
            account: a, api: FakeMailAPIClient(), store: try MailStore.inMemory()
        )

        await environment.signOut(accountID: a.id)
        await environment.drainPendingUsage()

        let removals = await tracker.events.filter { $0.name == "account_removed" }
        #expect(removals == [.accountRemoved])
        #expect(removals.first?.props.isEmpty == true)
    }
}
