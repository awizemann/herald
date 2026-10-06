import AppKit
import Foundation
import HeraldKit
import os
import Testing
@testable import Herald

/// Collects what the app tried to send, without an SDK behind it.
///
/// Not an actor: ``UsageTracking/record(_:)`` is synchronous (as the SDK's is),
/// and a spy that hopped to record would reorder exactly what these tests check.
/// State sits behind a lock; the getters stay `async` so call sites read the
/// same as against the real tracker.
nonisolated final class RecordingUsageTracker: UsageTracking, @unchecked Sendable {
    private struct State {
        var events: [UsageEvent] = []
        var activationCount = 0
        var flushCount = 0
        var enabledWrites: [Bool] = []
        var isEnabled = true
        var isAvailable = true
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func record(_ event: UsageEvent) { state.withLock { $0.events.append(event) } }
    func applicationDidBecomeActive() async { state.withLock { $0.activationCount += 1 } }
    func flush() async { state.withLock { $0.flushCount += 1 } }
    /// Records every opt-out write AND applies it, so a caller that re-reads
    /// `isEnabled` after writing (as the Settings toggle does) sees its own effect.
    func setEnabled(_ enabled: Bool) async {
        state.withLock {
            $0.enabledWrites.append(enabled)
            $0.isEnabled = enabled
        }
    }

    var events: [UsageEvent] { get async { state.withLock { $0.events } } }
    var activationCount: Int { get async { state.withLock { $0.activationCount } } }
    var flushCount: Int { get async { state.withLock { $0.flushCount } } }
    var enabledWrites: [Bool] { get async { state.withLock { $0.enabledWrites } } }
    var isEnabled: Bool { get async { state.withLock { $0.isEnabled } } }
    var isAvailable: Bool { state.withLock { $0.isAvailable } }

    /// Test-only: simulates the no-write-key build the toggle disables for.
    func makeUnavailable() async {
        state.withLock { $0.isAvailable = false }
    }

    var names: [String] { get async { state.withLock { $0.events.map(\.name) } } }

    /// Polls until at least `count` events have arrived, or the deadline passes.
    /// Never sleeps longer than it has to, and never asserts on a race: a caller
    /// that wants "exactly N" waits for an N+1th sentinel instead.
    @discardableResult
    func drain(until count: Int, deadline: Duration = .seconds(2)) async -> [UsageEvent] {
        let end = ContinuousClock.now.advanced(by: deadline)
        while await events.count < count, ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await events
    }
}

/// One view-model wired to a real ``AppEnvironment`` record path — the same
/// ordering guarantee production gets, rather than a hand-rolled substitute.
@MainActor
private struct UsageHarness {
    let store: MailStore
    let api: FakeMailAPIClient
    let environment: AppEnvironment
    let tracker: RecordingUsageTracker
    let model: MailViewModel
    let events: AsyncStream<SyncEvent>.Continuation

    /// - Parameter navigationDefaults: when given, the view-model persists and
    ///   restores its location there (the launch-restore tests); otherwise it
    ///   does neither, like every other view-model test.
    static func make(navigationDefaults: UserDefaults? = nil) async throws -> UsageHarness {
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
            defaults: navigationDefaults ?? .standard,
            persistsNavigation: navigationDefaults != nil,
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
        ScratchDefaults.make()
    }

    static func mailbox(_ id: String) -> Mailbox {
        Mailbox(
            id: id, address: "\(id)@example.com", addresses: [], displayName: id,
            isActive: true, accessLevel: .manager,
            createdAt: MailFixtures.epoch, updatedAt: MailFixtures.epoch
        )
    }
}

@MainActor
@Suite(.scratchDefaults) struct UsageRecordChainTests {

    /// Events arrive in the order they happened. Fails if `record` ever forks an
    /// independent task per event — which reorders under any real scheduler and
    /// is invisible in a single-event test.
    @Test func recordsAreDeliveredInCallOrder() async {
        let tracker = RecordingUsageTracker()
        let environment = AppEnvironment(
            defaults: UsageHarness.scratchDefaults(), usage: tracker
        )
        // Interleaved with awaits, i.e. with real scheduling opportunities
        // between the calls, which is where an unordered implementation loses.
        for index in 0..<50 {
            environment.record(.searchRun(localResults: UsageBucket(count: index), serverResults: nil))
            if index % 7 == 0 { await Task.yield() }
        }
        await environment.drainPendingUsage()

        let expected = (0..<50).map { UsageBucket(count: $0).rawValue }
        let received = await tracker.events.map { $0.props["local_results"] }
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

    /// A flush is a network send of up to 60s. Fails if one stuck in flight
    /// holds back an event recorded after it, or the next activation (whose
    /// `app_open` timestamp would be late by the same amount) — the head-of-line
    /// block Herald's old `Task` chain had.
    @Test func aStalledFlushHoldsBackNeitherEventsNorActivation() async throws {
        let tracker = StalledFlushTracker()
        let environment = AppEnvironment(defaults: UsageHarness.scratchDefaults(), usage: tracker)

        environment.recordFlush()
        await tracker.waitUntilFlushStarted()
        environment.record(.remoteMediaLoaded)
        #expect(tracker.events == [.remoteMediaLoaded], "the event waited behind the flush")

        environment.recordApplicationDidBecomeActive()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while tracker.activations == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(tracker.activations == 1, "the activation waited behind the flush")

        tracker.releaseFlush()
        await environment.drainPendingUsage()
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
@Suite(.scratchDefaults) struct UsageViewShownTests {

    /// The restore in `start()` assigns `location` directly, never through `navigate`, so the
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

    /// The launch restores where the account was left, and that must still be
    /// exactly ONE launch view — of the RESTORED folder. Run both with the
    /// mailbox list already cached and with a cold cache (the restore cannot
    /// judge the scope yet and keeps it). Fails if the restore is reported as a
    /// navigation of its own (a second `view_shown`), or if the launch view
    /// names the default folder rather than the restored one.
    @Test(arguments: [true, false])
    func theLaunchViewIsRecordedOnceAndNamesTheRestoredFolder(mailboxesCached: Bool) async throws {
        let defaults = ScratchDefaults.make()
        let restored = MailViewModel.Location(scope: .mailbox("mbA"), folder: .conversation(.archived), labelID: nil)
        NavigationPersistence.save(restored, accountID: "acct", to: defaults)
        let harness = try await UsageHarness.make(navigationDefaults: defaults)
        if mailboxesCached {
            try await harness.store.upsertMailboxes([UsageHarness.mailbox("mbA")], accountID: "acct")
        }

        await harness.model.start()
        harness.model.record(.remoteMediaLoaded)  // sentinel

        let events = await harness.recorded()
        let views = events.filter { $0.name == "view_shown" }
        #expect(views == [.viewShown(view: .archived, via: .launch)])
        #expect(harness.model.location == restored, "the restore must apply")
        #expect(events.last == .remoteMediaLoaded)
    }

    /// The other half of the old sidebar/`start()` race: a restored scope that
    /// could not be judged at launch (cold cache) and turns out to be GONE once
    /// the mailbox list arrives. Fails if the correction reports a second view,
    /// if it eats the source of the user's next click, or if the stale scope is
    /// kept (an empty list forever).
    @Test func aStaleRestoredScopeFallsBackSilentlyOnceMailboxesArrive() async throws {
        let defaults = ScratchDefaults.make()
        NavigationPersistence.save(
            MailViewModel.Location(scope: .mailbox("gone"), folder: .inbox, labelID: nil),
            accountID: "acct", to: defaults
        )
        let harness = try await UsageHarness.make(navigationDefaults: defaults)
        await harness.model.start()
        #expect(harness.model.scope == .mailbox("gone"), "nothing to judge it against yet")

        try await harness.store.upsertMailboxes([UsageHarness.mailbox("mbA")], accountID: "acct")
        harness.model.pendingNavigationSource = .sidebar
        await harness.model.reloadMailboxes()
        #expect(harness.model.scope == .allDomains)
        #expect(
            NavigationPersistence.load(accountID: "acct", from: defaults).scope == .allDomains,
            "the correction is what the next launch restores"
        )
        // The user's click, which set that source, now lands.
        harness.model.selectFolder(.conversation(.trash))

        let views = await harness.recorded().filter { $0.name == "view_shown" }
        #expect(views == [
            .viewShown(view: .inbox, via: .launch),
            .viewShown(view: .trash, via: .sidebar),
        ])
    }

    /// Fails if a no-op assignment (SwiftUI re-writing a `List` selection binding
    /// with the value it already has, which it does constantly) emits a view.
    @Test func aRealFolderChangeRecordsOnceAndASameValueSetRecordsNothing() async throws {
        let harness = try await UsageHarness.make()
        await harness.model.start()

        harness.model.pendingNavigationSource = .sidebar
        harness.model.showListing(mailboxID: nil, folder: .archived)
        harness.model.showListing(mailboxID: nil, folder: .archived)
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
        harness.model.showListing(mailboxID: nil, folder: .inbox)
        // …and now a navigation that says nothing about where it came from.
        harness.model.showListing(mailboxID: nil, folder: .trash)

        let views = await harness.recorded().filter { $0.name == "view_shown" }
        #expect(views.last == .viewShown(view: .trash, via: .other), "a stale `via` leaked")
    }

    /// Drafts is a folder like the others now. Fails if entering it is silent,
    /// or if leaving it for the folder that was showing before reports nothing
    /// (the pre-redesign trap: Drafts was a flag beside an unchanged selection).
    @Test func enteringAndLeavingDraftsBothReportAView() async throws {
        let harness = try await UsageHarness.make()
        await harness.model.start()

        harness.model.pendingNavigationSource = .sidebar
        harness.model.selectFolder(.drafts, clearingLabel: true)
        harness.model.pendingNavigationSource = .sidebar
        harness.model.selectFolder(.inbox, clearingLabel: true)

        let views = await harness.recorded().filter { $0.name == "view_shown" }
        #expect(views == [
            .viewShown(view: .inbox, via: .launch),
            .viewShown(view: .drafts, via: .sidebar),
            .viewShown(view: .inbox, via: .sidebar),
        ])
    }

    /// Leaving Drafts for a DIFFERENT folder is one navigation, to the folder the
    /// user picked. Fails if the folder being LEFT is reported on the way out — a
    /// phantom view nobody saw, ahead of the real one.
    @Test func leavingDraftsForAnotherFolderReportsOnlyTheDestination() async throws {
        let harness = try await UsageHarness.make()
        await harness.model.start()

        harness.model.pendingNavigationSource = .sidebar
        harness.model.selectFolder(.drafts, clearingLabel: true)
        harness.model.pendingNavigationSource = .sidebar
        harness.model.selectFolder(.conversation(.trash), clearingLabel: true)
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
        harness.model.showListing(mailboxID: nil, folder: .trash)

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
@Suite(.scratchDefaults) struct UsageScopeChangeTests {

    /// Drilling through the sidebar's three levels and back out is how a person
    /// moves between domains. Fails if a drill in, a back, or the All domains
    /// row is silent, if a folder change is miscounted as a scope change, or if
    /// the event ever carries more than the scope's kind.
    @Test func sidebarDrillInAndOutRecordsEachScopeChange() async throws {
        let harness = try await UsageHarness.make()
        await harness.model.start()
        try await harness.store.upsertMailboxes([UsageHarness.mailbox("mbA")], accountID: "acct")
        await harness.model.reloadMailboxes()
        let domain = try #require(harness.model.domains.first)

        harness.model.activate(.domain(domain.id))
        harness.model.activate(.mailbox("mbA"))
        harness.model.activate(.folder(.conversation(.trash)))
        harness.model.sidebarBack()
        harness.model.sidebarBack()
        harness.model.activate(.domain(domain.id))
        harness.model.activate(.allDomains)

        let scopes = await harness.recorded().filter { $0.name == "scope_changed" }
        #expect(scopes == [
            .scopeChanged(to: .domain, via: .sidebar),
            .scopeChanged(to: .mailbox, via: .sidebar),
            .scopeChanged(to: .domain, via: .sidebar),
            .scopeChanged(to: .allDomains, via: .sidebar),
            .scopeChanged(to: .domain, via: .sidebar),
            .scopeChanged(to: .allDomains, via: .sidebar),
        ])
    }

    /// A scope correction nobody asked for (a restored mailbox that no longer
    /// exists) is not the user changing domains. Fails if it is reported.
    @Test func aSilentScopeCorrectionIsNotReported() async throws {
        let defaults = ScratchDefaults.make()
        NavigationPersistence.save(
            MailViewModel.Location(scope: .mailbox("gone"), folder: .inbox, labelID: nil),
            accountID: "acct", to: defaults
        )
        let harness = try await UsageHarness.make(navigationDefaults: defaults)
        await harness.model.start()
        try await harness.store.upsertMailboxes([UsageHarness.mailbox("mbA")], accountID: "acct")
        await harness.model.reloadMailboxes()
        #expect(harness.model.scope == .allDomains)

        let names = await harness.recorded().map(\.name)
        #expect(!names.contains("scope_changed"))
    }
}

@MainActor
@Suite(.scratchDefaults) struct UsageSearchTests {

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
        #expect(runs == [.searchRun(localResults: .zero, serverResults: nil)])

        // Clearing the field is not a search either.
        harness.model.searchQuery = ""
        harness.model.submitSearch()
        harness.model.record(.remoteMediaLoaded)
        runs = await harness.recorded().filter { $0.name == "search_run" }
        #expect(runs.count == 1, "an empty needle is not a search")
    }
}

@MainActor
@Suite(.scratchDefaults) struct UsageActionAndSyncTests {

    /// Where an action came from is what answers "do people use the keyboard?"
    /// — and the count is a bucket, never a number. Fails if the entry point's
    /// `via` is lost or swapped on the way to the event, or if an exact count is
    /// ever attached.
    @Test(arguments: [UsageActionTrigger.toolbar, .keyboard, .menu])
    func aSelectionActionReportsWhereItWasTriggered(via: UsageActionTrigger) async throws {
        let harness = try await UsageHarness.make()
        let message = MailFixtures.message(id: "m1", threadID: "t1", mailboxID: "mbA")
        try await harness.store.upsertMessages([message], accountID: "acct")
        try await harness.store.upsertConversations(
            [MailFixtures.conversation(message)], accountID: "acct", mailboxID: nil, folder: .inbox
        )
        await harness.model.start()
        harness.model.select("t1", drill: false)

        await harness.model.performOnSelection(.archive, via: via)

        let performed = await harness.recorded().filter { $0.name == "message_action_performed" }
        #expect(performed == [
            .messageActionPerformed(action: .archive, scope: .conversation, via: via, count: .one)
        ])
        for event in performed {
            #expect(event.props["count"] == .string("1"), "counts are only ever bucketed")
        }
    }

    /// The trigger is derived, because ``SyncEvent`` carries none: the first pass
    /// is the launch, an explicit refresh claims the next completion, and
    /// everything after that is the cadence — which is NOT reported. Fails if a
    /// post-action refresh is ever reported as something the user asked for, or
    /// if a cadence success reaches the tracker (at 15s a pass, that kept a
    /// session open for as long as Herald sat in front of an idle Mac).
    @Test func launchAndManualPassesAreReportedAndCadenceSuccessesAreNot() async throws {
        let harness = try await UsageHarness.make()
        await harness.model.start()

        // One pass at a time, each awaited before the next is provoked: the
        // events are consumed on a task of their own, so firing all of them at
        // once would be asserting on the interleaving rather than on the rule.
        harness.events.yield(.began)
        harness.events.yield(.finished)
        await harness.tracker.drain(until: 2)  // launch view + first completion

        // Two cadence successes, then a cadence FAILURE — reported, because sync
        // just broke — as the barrier: the successes must be consumed before the
        // Refresh claims a trigger, or one of them would take it.
        for _ in 0..<2 {
            harness.events.yield(.began)
            harness.events.yield(.finished)
        }
        harness.events.yield(.began)
        harness.events.yield(.failed(MailAPIError.decoding))
        await harness.tracker.drain(until: 3)

        await harness.model.refresh()
        harness.events.yield(.began)
        harness.events.yield(.changed(ChangeSet(updated: ["m1"])))
        harness.events.yield(.finished)
        await harness.tracker.drain(until: 4)
        await harness.settle()
        let syncs = await harness.tracker.events.filter { $0.name == "sync_completed" }
        #expect(syncs == [
            .syncCompleted(trigger: .launch, changed: false),
            .syncCompleted(trigger: .manual, changed: true),
        ])
    }

    /// The moment sync BREAKS is worth one event; every poll that fails after it
    /// is the same news. Fails if a run of cadence failures reports more than
    /// once, or if a recovery followed by a new failure is not reported again.
    @Test func cadenceFailuresAreReportedOnlyWhenSyncBreaks() async throws {
        let harness = try await UsageHarness.make()
        await harness.model.start()
        harness.events.yield(.began)
        harness.events.yield(.finished)
        await harness.tracker.drain(until: 2)  // launch view + launch completion

        for _ in 0..<3 {  // broken: one report
            harness.events.yield(.began)
            harness.events.yield(.failed(MailAPIError.cursorExpired))
        }
        harness.events.yield(.began)  // recovered: not reported (cadence success)
        harness.events.yield(.finished)
        harness.events.yield(.began)  // broken again: reported
        harness.events.yield(.failed(MailAPIError.decoding))
        await harness.tracker.drain(until: 4)
        await harness.settle()

        let failures = await harness.tracker.events.filter { $0.name == "sync_failed" }
        #expect(failures == [
            .syncFailed(kind: .cursorExpired, trigger: .auto),
            .syncFailed(kind: .decoding, trigger: .auto),
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

    /// swift-stats opens a session on any tracked event, so a pass reported while
    /// Herald is in the background would make an unattended Mac look in use.
    /// Fails if a backgrounded pass — completed OR failed — reaches the tracker,
    /// or if dropping it disturbs the attribution of the next reported pass.
    @Test func passesWhileInactiveAreNotReported() async throws {
        let harness = try await UsageHarness.make()
        await harness.model.start()

        harness.events.yield(.began)
        harness.events.yield(.finished)
        await harness.tracker.drain(until: 2)  // launch view + launch completion

        await harness.model.setActive(false)
        harness.events.yield(.began)
        harness.events.yield(.finished)
        harness.events.yield(.began)
        harness.events.yield(.failed(MailAPIError.cursorExpired))
        // The gate is read when an event is CONSUMED, on the view-model's own
        // task, so both inactive passes must be consumed before reactivating —
        // the `.failed` status is the last thing they leave behind.
        try await wait("both backgrounded passes consumed") {
            if case .failed = harness.model.status { return true }
            return false
        }

        // The barrier: the next event recorded is a Refresh after reactivation,
        // so anything the inactive passes leaked lands before it.
        await harness.model.setActive(true)
        await harness.model.refresh()
        harness.events.yield(.began)
        harness.events.yield(.finished)
        await harness.tracker.drain(until: 3)
        await harness.settle()

        let syncs = await harness.tracker.events.filter { $0.name.hasPrefix("sync_") }
        #expect(syncs == [
            .syncCompleted(trigger: .launch, changed: false),
            .syncCompleted(trigger: .manual, changed: false),
        ])
    }
}

@MainActor
@Suite(.scratchDefaults) struct UsageAccountTests {

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

    /// The Settings window's account card switches the same shared selection
    /// as the main window's popover, so it must report the same event. Fails if
    /// the Settings path goes around the counted assignment (e.g. through
    /// `selectAccount`), or if re-picking the current account counts.
    @Test func switchingFromTheSettingsCardIsAnAccountSwitch() async throws {
        let tracker = RecordingUsageTracker()
        let environment = AppEnvironment(
            defaults: UsageHarness.scratchDefaults(), usage: tracker
        )
        let store = try MailStore.inMemory()
        let a = Account(origin: URL(string: "https://a.example.com")!, clientID: "cid", scopes: [])
        let b = Account(origin: URL(string: "https://b.example.com")!, clientID: "cid", scopes: [])
        await environment.install(account: a, api: FakeMailAPIClient(), store: store)
        await environment.install(account: b, api: FakeMailAPIClient(), store: store, select: false)

        environment.selectAccountFromSettings(a.id) // already current: not a switch
        environment.selectAccountFromSettings(b.id)
        await environment.drainPendingUsage()
        #expect(environment.selectedAccountID == b.id)
        let switches = await tracker.events.filter { $0.name == "account_switched" }
        #expect(switches == [.accountSwitched(accounts: .twoToFive)])
    }

    /// A banner click is ONE `notification_opened` — whether it launched Herald
    /// (held until its account comes up, then replayed) or landed on a live
    /// window. Fails if the account assignment it causes is also counted as a
    /// switch, which made every click read as two or more navigations.
    @Test func aBannerClickIsOneNotificationOpenedAndNeverASwitch() async throws {
        let tracker = RecordingUsageTracker()
        let environment = AppEnvironment(
            defaults: UsageHarness.scratchDefaults(), usage: tracker
        )
        let store = try MailStore.inMemory()
        let a = Account(origin: URL(string: "https://a.example.com")!, clientID: "cid", scopes: [])
        let b = Account(origin: URL(string: "https://b.example.com")!, clientID: "cid", scopes: [])
        await environment.install(account: a, api: FakeMailAPIClient(), store: store)

        // Names an account that is not up yet: held, then replayed by `install`.
        await environment.open(NewMailRoute(accountID: b.id, threadID: nil, messageID: nil))
        #expect(await tracker.names.contains("notification_opened") == false, "reported before it was handled")
        await environment.install(account: b, api: FakeMailAPIClient(), store: store, select: false)
        #expect(environment.selectedAccountID == b.id, "the replay must still switch the window")

        // The same kind of click on a live window.
        await environment.open(NewMailRoute(accountID: a.id, threadID: nil, messageID: nil))
        #expect(environment.selectedAccountID == a.id)

        #expect(await tracker.names.contains("account_switched") == false, "a banner click is not a switch")
        let opened = await tracker.events.filter { $0.name == "notification_opened" }
        #expect(opened == [.notificationOpened(landed: true), .notificationOpened(landed: true)])
        for graph in environment.graphs.values { await graph.stop() }
    }

    /// Fails if a banner whose conversation has gone since (archived, trashed)
    /// reports that it landed — the one thing `landed` exists to tell apart.
    @Test func aBannerForAConversationThatIsGoneDidNotLand() async throws {
        let tracker = RecordingUsageTracker()
        let environment = AppEnvironment(defaults: UsageHarness.scratchDefaults(), usage: tracker)
        let a = Account(origin: URL(string: "https://a.example.com")!, clientID: "cid", scopes: [])
        await environment.install(account: a, api: FakeMailAPIClient(), store: try MailStore.inMemory())

        await environment.open(NewMailRoute(accountID: a.id, threadID: "gone", messageID: "m-gone"))

        let opened = await tracker.events.filter { $0.name == "notification_opened" }
        #expect(opened == [.notificationOpened(landed: false)])
        for graph in environment.graphs.values { await graph.stop() }
    }

    /// Add Account's two pre-OAuth refusals are different user problems. Fails
    /// if either reports `failed` with no reason (indistinguishable on the
    /// dashboard), or if what the user typed ever becomes a prop.
    @Test func addAccountRefusalsCarryTheirReason() async throws {
        let tracker = RecordingUsageTracker()
        let a = Account(origin: URL(string: "https://a.example.com")!, clientID: "cid", scopes: [])
        let environment = AppEnvironment(
            auth: AuthCoordinator(store: InMemoryAccountStore()),
            defaults: UsageHarness.scratchDefaults(),
            usage: tracker
        )
        await environment.install(account: a, api: FakeMailAPIClient(), store: try MailStore.inMemory())

        await environment.signIn(originText: "not a server at all ::")
        await environment.signIn(originText: "https://A.example.com/")

        let added = await tracker.events.filter { $0.name == "account_added" }
        #expect(added == [
            .accountAdded(outcome: .failed, kind: .invalidOrigin, accounts: nil),
            .accountAdded(outcome: .failed, kind: .alreadyAdded, accounts: nil),
        ])
        for event in added {
            #expect(!event.props.values.contains { $0 == .string("not a server at all ::") })
        }
        for graph in environment.graphs.values { await graph.stop() }
    }

    /// `compose_opened` counts windows, not requests. Fails if a request that
    /// cannot open one (no account to compose from) is still reported.
    @Test func composeOpenedIsReportedOnlyWhenAWindowCanOpen() async throws {
        let tracker = RecordingUsageTracker()
        let environment = AppEnvironment(defaults: UsageHarness.scratchDefaults(), usage: tracker)
        #expect(await environment.prepareCompose(ComposeRequest(kind: .new)) == nil)
        #expect(await tracker.names.contains("compose_opened") == false)

        let a = Account(origin: URL(string: "https://a.example.com")!, clientID: "cid", scopes: [])
        await environment.install(account: a, api: FakeMailAPIClient(), store: try MailStore.inMemory())
        #expect(await environment.prepareCompose(ComposeRequest(kind: .new)) != nil)
        let opened = await tracker.events.filter { $0.name == "compose_opened" }
        #expect(opened == [.composeOpened(kind: .new)])
        for graph in environment.graphs.values { await graph.stop() }
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

/// A tracker whose `flush()` parks until released — a send stuck on the network.
private nonisolated final class StalledFlushTracker: UsageTracking, @unchecked Sendable {
    private struct State {
        var events: [UsageEvent] = []
        var activations = 0
        var flushStarted = false
        var release: CheckedContinuation<Void, Never>?
        var released = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var events: [UsageEvent] { state.withLock { $0.events } }
    var activations: Int { state.withLock { $0.activations } }
    var isAvailable: Bool { true }
    var isEnabled: Bool { get async { true } }

    func record(_ event: UsageEvent) { state.withLock { $0.events.append(event) } }
    func applicationDidBecomeActive() async { state.withLock { $0.activations += 1 } }
    func setEnabled(_ enabled: Bool) async {}
    func flush() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { s -> Bool in
                s.flushStarted = true
                if s.released { return true }
                s.release = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func waitUntilFlushStarted() async {
        for _ in 0..<10_000 where !state.withLock({ $0.flushStarted }) { await Task.yield() }
    }

    func releaseFlush() {
        let continuation = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.released = true
            defer { s.release = nil }
            return s.release
        }
        continuation?.resume()
    }
}
