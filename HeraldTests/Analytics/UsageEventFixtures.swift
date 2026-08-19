import Foundation
@testable import Herald

/// Every `UsageEvent` case, exactly once — and a compile-plus-test gate that keeps
/// it that way.
///
/// How the gate works:
/// 1. ``discriminant(of:)`` is an **exhaustive `switch` with no `default`**. Adding a
///    case to ``UsageEvent`` fails to COMPILE until an arm is added here.
/// 2. The new arm must carry the next discriminant, so ``caseCount`` goes up.
/// 3. `everyEventCaseHasAFixture` asserts `Set(all.map(discriminant)).count == caseCount`,
///    so the build only goes green once ``all`` also gains a fixture for the new case.
///
/// Net effect: a new event cannot ship without passing the name, vocabulary and
/// payload-leak assertions in `UsageEventContractTests`.
nonisolated enum UsageEventFixtures {
    /// One representative value per case.
    static let all: [UsageEvent] = [
        .viewShown(view: .inbox, via: .launch),
        .syncCompleted(trigger: .manual, changed: true),
        .syncFailed(kind: .transport, trigger: .auto),
        .messageActionPerformed(action: .archive, scope: .selection, count: .twoToFive),
        .actionFailed(action: .trash, kind: .unauthorized),
        .searchRun(scope: .server, results: .sixToTwenty),
        .searchFailed(kind: .decoding),
        .composeOpened(kind: .replyAll),
        .draftSaved,
        .messageSent(attachments: .one, hasCC: true, hasBCC: false),
        .sendFailed(kind: .api(.server)),
        .composeDiscarded,
        .draftDeleted,
        .attachmentSaved,
        .remoteMediaLoaded,
        .accountAdded(outcome: .failed, kind: .stateMismatch),
        .accountReauthenticated(outcome: .success, kind: nil),
        .accountRemoved,
        .accountSwitched(accounts: .twentyPlus),
        .notificationsToggled(enabled: true),
        .mailboxColorChanged,
        .updateCheckRequested,
        .launchFailed(kind: .cache),
    ]

    /// The number of arms in ``discriminant(of:)``. Bump it when you add one.
    static let caseCount = 23

    /// Exhaustive, no `default`. See the gate description above.
    static func discriminant(of event: UsageEvent) -> Int {
        switch event {
        case .viewShown: 0
        case .syncCompleted: 1
        case .syncFailed: 2
        case .messageActionPerformed: 3
        case .actionFailed: 4
        case .searchRun: 5
        case .searchFailed: 6
        case .composeOpened: 7
        case .draftSaved: 8
        case .messageSent: 9
        case .sendFailed: 10
        case .composeDiscarded: 11
        case .draftDeleted: 12
        case .attachmentSaved: 13
        case .remoteMediaLoaded: 14
        case .accountAdded: 15
        case .accountReauthenticated: 16
        case .accountRemoved: 17
        case .accountSwitched: 18
        case .notificationsToggled: 19
        case .mailboxColorChanged: 20
        case .updateCheckRequested: 21
        case .launchFailed: 22
        }
    }
}
