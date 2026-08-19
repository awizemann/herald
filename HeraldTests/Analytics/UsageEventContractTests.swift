import Foundation
import Stats
import Testing
@testable import Herald

/// The privacy contract, enforced.
///
/// These tests are the reason `UsageEvent.swift` can be audited by reading it: they
/// pin the wire names, pin the exact vocabulary each string prop may draw from, and
/// prove the fixture list covers every case. Every vocabulary below is written out
/// as a **literal**, deliberately NOT derived from the enums under test — a set
/// built from `allCases` would happily agree with a case that was renamed to leak
/// something, which is exactly the change these tests exist to catch.
@Suite struct UsageEventContractTests {

    // MARK: Literal vocabularies

    static let buckets: Set<String> = ["0", "1", "2_5", "6_20", "20_plus"]
    static let views: Set<String> = [
        "inbox", "sent", "starred", "archived", "trash", "catchall", "drafts", "thread",
    ]
    static let viaTriggers: Set<String> = [
        "launch", "sidebar", "search", "notification", "shortcut", "other",
    ]
    static let syncTriggers: Set<String> = ["manual", "auto", "launch"]
    static let messageActions: Set<String> = [
        "read", "unread", "star", "unstar", "archive", "trash",
    ]
    static let actionScopes: Set<String> = ["message", "conversation", "selection"]
    static let searchScopes: Set<String> = ["local", "server"]
    static let composeKinds: Set<String> = ["new", "reply", "reply_all", "forward", "draft"]
    static let accountOutcomes: Set<String> = ["success", "cancelled", "failed"]
    static let launchFailureKinds: Set<String> = ["cache", "restore", "other"]
    static let mailErrorKinds: Set<String> = [
        "unauthorized", "insufficient_scope", "not_found", "cursor_expired",
        "server", "transport", "decoding", "other",
    ]
    static let oauthErrorKinds: Set<String> = [
        "discovery", "registration", "server", "state_mismatch", "missing_code",
        "reauth_required", "missing_refresh_token", "malformed_token", "cancelled",
        "web_auth", "unknown_account", "transport", "other",
    ]
    static let outboxErrorKinds: Set<String> = [
        "invalid_recipient", "no_recipients", "attachment_too_large", "draft_too_large",
        "too_many_attachments", "draft_conflict", "file_unreadable",
        "api_unauthorized", "api_insufficient_scope", "api_not_found", "api_cursor_expired",
        "api_server", "api_transport", "api_decoding", "api_other",
    ]

    /// event name → prop key → the complete set of string values that prop may take.
    /// A key absent from an event's map here is a key that event must never emit.
    /// A key mapped to `nil` is a non-string (Bool) prop.
    static let vocabulary: [String: [String: Set<String>?]] = [
        "view_shown": ["view": views, "via": viaTriggers],
        "sync_completed": ["trigger": syncTriggers, "changed": Set<String>?.none],
        "sync_failed": ["kind": mailErrorKinds, "trigger": syncTriggers],
        "message_action_performed": [
            "action": messageActions, "scope": actionScopes, "count": buckets,
        ],
        "action_failed": ["action": messageActions, "kind": mailErrorKinds],
        "search_run": ["scope": searchScopes, "results": buckets],
        "search_failed": ["kind": mailErrorKinds],
        "compose_opened": ["kind": composeKinds],
        "draft_saved": [:],
        "message_sent": [
            "attachments": buckets,
            "has_cc": Set<String>?.none,
            "has_bcc": Set<String>?.none,
        ],
        "send_failed": ["kind": outboxErrorKinds],
        "compose_discarded": [:],
        "draft_deleted": [:],
        "attachment_saved": [:],
        "remote_media_loaded": [:],
        "account_added": ["outcome": accountOutcomes, "kind": oauthErrorKinds],
        "account_reauthenticated": ["outcome": accountOutcomes, "kind": oauthErrorKinds],
        "account_removed": [:],
        "account_switched": ["accounts": buckets],
        "notifications_toggled": ["enabled": Set<String>?.none],
        "mailbox_color_changed": [:],
        "update_check_requested": [:],
        "launch_failed": ["kind": launchFailureKinds],
    ]

    // MARK: Coverage

    /// Fails when `UsageEvent` gains a case and `UsageEventFixtures.all` does not —
    /// which would let a new event skip every assertion in this suite. The exhaustive
    /// `switch` in `discriminant(of:)` catches the case at compile time; this catches
    /// the missing fixture.
    @Test func everyEventCaseHasAFixture() {
        let covered = Set(UsageEventFixtures.all.map(UsageEventFixtures.discriminant(of:)))
        #expect(covered.count == UsageEventFixtures.caseCount)
        #expect(UsageEventFixtures.all.count == UsageEventFixtures.caseCount)
    }

    /// Fails if two cases were ever given the same wire name — which would silently
    /// merge two different behaviours into one number on the dashboard.
    @Test func everyEventNameIsDistinct() {
        let names = UsageEventFixtures.all.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(Set(names) == Set(Self.vocabulary.keys))
    }

    // MARK: Names

    /// Fails on a name the backend would reject the whole batch for (schema §2.1),
    /// or on one that collides with the SDK's own reserved auto-events (§12) —
    /// either of which loses data silently in production.
    @Test(arguments: UsageEventFixtures.all)
    func eventNameIsWellFormedAndUnreserved(event: UsageEvent) {
        let name = event.name
        #expect(matchesSnakeCase(name), "\(name) must match ^[a-z][a-z0-9_]*$")
        #expect(name.unicodeScalars.count <= 64)
        #expect(!["app_open", "app_background", "session_start", "session_end"].contains(name))
        #expect(!name.hasPrefix("stats_"))
        // Cross-check against the SDK's own validator, so a schema tightening in a
        // future swift-stats release fails here rather than at the backend.
        #expect(StatsEventName.isValidForApp(name))
    }

    // MARK: Props

    /// The core privacy assertion: every string that can reach the wire is drawn from
    /// a set written out by hand in this file. Fails if a prop value ever becomes a
    /// name, an address, a message, an id, or anything else free-form.
    @Test(arguments: UsageEventFixtures.all)
    func propsStayInsideTheirDeclaredVocabulary(event: UsageEvent) throws {
        let allowed = try #require(Self.vocabulary[event.name], "no vocabulary declared for \(event.name)")
        for (key, value) in event.props {
            #expect(matchesSnakeCase(key), "\(key) must match ^[a-z][a-z0-9_]*$")
            #expect(key.unicodeScalars.count <= 40)
            let declared = try #require(allowed[key], "\(event.name) emitted undeclared prop \(key)")
            switch value {
            case .string(let string):
                let vocabulary = try #require(declared, "\(event.name).\(key) is declared non-string")
                #expect(vocabulary.contains(string), "\(event.name).\(key) = \(string) is outside its vocabulary")
            case .bool:
                #expect(declared == nil, "\(event.name).\(key) is declared a string prop")
            }
            // There is no numeric arm: `UsageValue` has no `int` case, so a prop
            // carrying an exact count cannot be written in the first place. This
            // switch being exhaustive over two cases IS that guarantee — adding
            // one back stops this file compiling.
        }
    }

    /// Fails if a case of a vocabulary enum is renamed or added without the literal
    /// vocabulary above being updated — the mutation that would let a fixture pass
    /// while the shipping value drifted.
    @Test func closedEnumRawValuesMatchTheDeclaredVocabularies() {
        #expect(Set(UsageBucket.allCases.map(\.rawValue)) == Self.buckets)
        #expect(Set(UsageViewKind.allCases.map(\.rawValue)) == Self.views)
        #expect(Set(UsageViewTrigger.allCases.map(\.rawValue)) == Self.viaTriggers)
        #expect(Set(UsageSyncTrigger.allCases.map(\.rawValue)) == Self.syncTriggers)
        #expect(Set(UsageMessageAction.allCases.map(\.rawValue)) == Self.messageActions)
        #expect(Set(UsageActionScope.allCases.map(\.rawValue)) == Self.actionScopes)
        #expect(Set(UsageSearchScope.allCases.map(\.rawValue)) == Self.searchScopes)
        #expect(Set(UsageComposeKind.allCases.map(\.rawValue)) == Self.composeKinds)
        #expect(Set(UsageAccountOutcome.allCases.map(\.rawValue)) == Self.accountOutcomes)
        #expect(Set(UsageLaunchFailureKind.allCases.map(\.rawValue)) == Self.launchFailureKinds)
        #expect(Set(UsageMailErrorKind.allCases.map(\.rawValue)) == Self.mailErrorKinds)
        #expect(Set(UsageOAuthErrorKind.allCases.map(\.rawValue)) == Self.oauthErrorKinds)
        #expect(UsageOutboxErrorKind.allRawValues == Self.outboxErrorKinds)
    }

    // MARK: Buckets

    /// Fails if a boundary ever moves — the boundaries are the only thing standing
    /// between a "coarse bucket" and a reportable exact count.
    @Test(arguments: [
        (0, UsageBucket.zero), (-3, .zero),
        (1, .one),
        (2, .twoToFive), (5, .twoToFive),
        (6, .sixToTwenty), (20, .sixToTwenty),
        (21, .twentyPlus), (5_000, .twentyPlus),
    ])
    func bucketBoundaries(count: Int, expected: UsageBucket) {
        #expect(UsageBucket(count: count) == expected)
    }

    // MARK: Helper

    /// `^[a-z][a-z0-9_]*$`, checked here rather than borrowed from the SDK so this
    /// suite still fails if the SDK's validator is ever loosened.
    private func matchesSnakeCase(_ candidate: String) -> Bool {
        guard let first = candidate.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return candidate.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
        }
    }
}
