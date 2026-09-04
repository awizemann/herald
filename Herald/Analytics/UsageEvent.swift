import Foundation
import HeraldKit
import Stats

// MARK: - Privacy contract
//
// THIS FILE IS THE PRIVACY CONTRACT for Herald's usage analytics. Every event that
// can ever reach the backend is a case of `UsageEvent`, and every property that can
// ever be attached to one is produced by `UsageEvent.props` below. There is no other
// way to emit: `UsageTracking.track(_:)` takes a `UsageEvent`, never a free string
// and never a free dictionary, so this file is the complete, auditable list.
//
// The only shapes a property value may take are:
//   • the raw value of a CLOSED enum declared in this file (a fixed vocabulary),
//   • a Bool,
//   • a `UsageBucket` (a coarse, order-of-magnitude count).
// Anything else is a bug in this file.
//
// MUST NEVER be a prop value — not truncated, not hashed, not "just the domain":
//   • search text, or any other text a person typed
//   • mailbox / folder / label names, and mailbox colour tokens
//   • account origins, server URLs, hostnames, or email addresses
//   • message subjects, snippets, bodies, or any header value
//   • attachment file names, paths, extensions, or byte sizes
//   • message / thread / draft / account / mailbox identifiers of any kind
//   • error messages, `localizedDescription`, server `message`/`code` payloads,
//     OAuth `error_description`, URLs from `OAuthError.discoveryFailed`
//   • exact counts of anything (unread counts, message counts, result counts):
//     counts are only ever reported through `UsageBucket`
//   • tokens, refresh tokens, verifiers, keys
//   • version strings beyond the SDK's own context block
//
// Error mapping rule: every error is reduced to a fixed `kind` vocabulary by an
// EXPLICIT `switch` over the error enum's cases. Never `Mirror`, never
// `String(describing:)`, never `errorDescription`, never `logCode` (which
// interpolates limits and transport domains). The switches below deliberately bind
// no associated values, so a payload cannot leak by accident; adding a case to one
// of the upstream error enums breaks the build here, which is the point.

// MARK: - Bucket

/// A coarse count. Exact counts are never reported — see the privacy contract above.
nonisolated enum UsageBucket: String, Sendable, Hashable, CaseIterable {
    case zero = "0"
    case one = "1"
    case twoToFive = "2_5"
    case sixToTwenty = "6_20"
    case twentyPlus = "20_plus"

    init(count: Int) {
        switch count {
        case ..<1: self = .zero
        case 1: self = .one
        case 2...5: self = .twoToFive
        case 6...20: self = .sixToTwenty
        default: self = .twentyPlus
        }
    }
}

// MARK: - Closed vocabularies

nonisolated enum UsageViewKind: String, Sendable, Hashable, CaseIterable {
    case inbox, sent, starred, archived, trash, catchall, drafts, thread
}

nonisolated enum UsageViewTrigger: String, Sendable, Hashable, CaseIterable {
    case launch, sidebar, search, notification, shortcut, other
}

nonisolated enum UsageSyncTrigger: String, Sendable, Hashable, CaseIterable {
    case manual, auto, launch
}

nonisolated enum UsageMessageAction: String, Sendable, Hashable, CaseIterable {
    case read, unread, star, unstar, archive, unarchive, trash, restore
}

nonisolated enum UsageActionScope: String, Sendable, Hashable, CaseIterable {
    case message, conversation, selection
}

nonisolated enum UsageSearchScope: String, Sendable, Hashable, CaseIterable {
    case local, server
}

nonisolated enum UsageComposeKind: String, Sendable, Hashable, CaseIterable {
    case new
    case reply
    case replyAll = "reply_all"
    case forward
    case draft
}

nonisolated enum UsageAccountOutcome: String, Sendable, Hashable, CaseIterable {
    case success, cancelled, failed
}

nonisolated enum UsageLaunchFailureKind: String, Sendable, Hashable, CaseIterable {
    case cache, restore, other
}

// MARK: - Error kinds

/// ``MailAPIError`` reduced to a fixed vocabulary. No associated value is bound:
/// the scope string, the server code/message and the transport domain never leave
/// the device.
nonisolated enum UsageMailErrorKind: String, Sendable, Hashable, CaseIterable {
    case unauthorized
    case insufficientScope = "insufficient_scope"
    case notFound = "not_found"
    case cursorExpired = "cursor_expired"
    case server
    case transport
    case decoding
    /// Anything that is not a ``MailAPIError`` at all. A failure with no kind used
    /// to be dropped, which made "how often does this fail?" unanswerable; the
    /// fallback keeps the count without keeping the error.
    case other

    /// Classifies ANY error: a `MailAPIError` by its case, everything else as
    /// ``other``. Nothing of a foreign error survives — not its type name, not
    /// its domain, not its message.
    init(anyError: any Error) {
        if let api = anyError as? MailAPIError {
            self.init(api)
        } else {
            self = .other
        }
    }

    init(_ error: MailAPIError) {
        switch error {
        case .unauthorized: self = .unauthorized
        case .insufficientScope: self = .insufficientScope
        case .notFound: self = .notFound
        case .cursorExpired: self = .cursorExpired
        case .server: self = .server
        case .transport: self = .transport
        case .decoding: self = .decoding
        }
    }
}

/// ``OAuthError`` reduced to a fixed vocabulary. The discovery URL, the server's
/// `error`/`error_description`, the `webAuthenticationFailed` reason and the account
/// id are all dropped here and never reach a prop.
nonisolated enum UsageOAuthErrorKind: String, Sendable, Hashable, CaseIterable {
    case discovery
    case registration
    case server
    case stateMismatch = "state_mismatch"
    case missingCode = "missing_code"
    case reauthRequired = "reauth_required"
    case missingRefreshToken = "missing_refresh_token"
    case malformedToken = "malformed_token"
    case cancelled
    case webAuth = "web_auth"
    case unknownAccount = "unknown_account"
    case transport
    /// Anything that is not an ``OAuthError`` at all — see ``UsageMailErrorKind.other``.
    case other

    /// Classifies ANY error, keeping nothing of a foreign one.
    init(anyError: any Error) {
        if let oauth = anyError as? OAuthError {
            self.init(oauth)
        } else {
            self = .other
        }
    }

    init(_ error: OAuthError) {
        switch error {
        case .discoveryFailed: self = .discovery
        case .registrationUnsupported, .registrationFailed: self = .registration
        case .server: self = .server
        case .stateMismatch: self = .stateMismatch
        case .missingAuthorizationCode: self = .missingCode
        case .reauthenticationRequired: self = .reauthRequired
        case .missingRefreshToken: self = .missingRefreshToken
        case .malformedTokenResponse: self = .malformedToken
        case .userCancelled: self = .cancelled
        case .webAuthenticationFailed: self = .webAuth
        case .unknownAccount: self = .unknownAccount
        case .transport: self = .transport
        }
    }
}

/// ``OutboxError`` reduced to a fixed vocabulary. The offending address, the byte
/// counts, the attachment limits and the unreadable file's URL are all dropped;
/// an API failure keeps only the ``UsageMailErrorKind`` behind an `api_` prefix.
nonisolated enum UsageOutboxErrorKind: Sendable, Hashable {
    case invalidRecipient
    case noRecipients
    case attachmentTooLarge
    case draftTooLarge
    case tooManyAttachments
    case draftConflict
    case api(UsageMailErrorKind)
    case fileUnreadable

    init(_ error: OutboxError) {
        switch error {
        case .invalidRecipient: self = .invalidRecipient
        case .noRecipients: self = .noRecipients
        case .attachmentTooLarge: self = .attachmentTooLarge
        case .draftTooLarge: self = .draftTooLarge
        case .tooManyAttachments: self = .tooManyAttachments
        case .draftConflict: self = .draftConflict
        case .api(let apiError): self = .api(UsageMailErrorKind(apiError))
        case .fileUnreadable: self = .fileUnreadable
        }
    }

    var rawValue: String {
        switch self {
        case .invalidRecipient: "invalid_recipient"
        case .noRecipients: "no_recipients"
        case .attachmentTooLarge: "attachment_too_large"
        case .draftTooLarge: "draft_too_large"
        case .tooManyAttachments: "too_many_attachments"
        case .draftConflict: "draft_conflict"
        case .api(let kind): "api_\(kind.rawValue)"
        case .fileUnreadable: "file_unreadable"
        }
    }

    /// The complete vocabulary, for the privacy test and for documentation.
    static var allRawValues: Set<String> {
        var values: Set<String> = [
            "invalid_recipient", "no_recipients", "attachment_too_large", "draft_too_large",
            "too_many_attachments", "draft_conflict", "file_unreadable",
        ]
        for kind in UsageMailErrorKind.allCases { values.insert("api_\(kind.rawValue)") }
        return values
    }
}

// MARK: - Prop values

/// The only two value shapes a Herald prop may take. Deliberately narrower than
/// ``StatsValue`` (no `int`, no `double`, no `null`) so nothing numeric — a count,
/// a duration, a byte size, a ratio — can be attached without changing this file:
/// counts only ever reach the wire as a ``UsageBucket``'s raw string.
nonisolated enum UsageValue: Sendable, Hashable {
    case string(String)
    case bool(Bool)

    var statsValue: StatsValue {
        switch self {
        case .string(let value): .string(value)
        case .bool(let value): .bool(value)
        }
    }
}

// MARK: - Events

/// Every usage event Herald can emit. One case per row of the approved plan.
///
/// Adding a case here is a privacy decision: it must also be added to the
/// exhaustive fixture switch in `UsageEventContractTests`, which will not compile
/// until it is.
nonisolated enum UsageEvent: Sendable, Hashable {
    case viewShown(view: UsageViewKind, via: UsageViewTrigger)
    case syncCompleted(trigger: UsageSyncTrigger, changed: Bool)
    case syncFailed(kind: UsageMailErrorKind, trigger: UsageSyncTrigger)
    case messageActionPerformed(action: UsageMessageAction, scope: UsageActionScope, count: UsageBucket)
    case actionFailed(action: UsageMessageAction, kind: UsageMailErrorKind)
    case searchRun(scope: UsageSearchScope, results: UsageBucket)
    case searchFailed(kind: UsageMailErrorKind)
    case composeOpened(kind: UsageComposeKind)
    case draftSaved
    case messageSent(attachments: UsageBucket, hasCC: Bool, hasBCC: Bool)
    case sendFailed(kind: UsageOutboxErrorKind)
    case composeDiscarded
    case draftDeleted
    case attachmentSaved
    case remoteMediaLoaded
    case accountAdded(outcome: UsageAccountOutcome, kind: UsageOAuthErrorKind?)
    case accountReauthenticated(outcome: UsageAccountOutcome, kind: UsageOAuthErrorKind?)
    case accountRemoved
    case accountSwitched(accounts: UsageBucket)
    case notificationsToggled(enabled: Bool)
    case mailboxColorChanged
    case updateCheckRequested
    case launchFailed(kind: UsageLaunchFailureKind)

    /// The wire name. `^[a-z][a-z0-9_]*$`, ≤ 64 scalars, never one of the four
    /// reserved auto-event names and never `stats_`-prefixed (schema §2.1, §12).
    var name: String {
        switch self {
        case .viewShown: "view_shown"
        case .syncCompleted: "sync_completed"
        case .syncFailed: "sync_failed"
        case .messageActionPerformed: "message_action_performed"
        case .actionFailed: "action_failed"
        case .searchRun: "search_run"
        case .searchFailed: "search_failed"
        case .composeOpened: "compose_opened"
        case .draftSaved: "draft_saved"
        case .messageSent: "message_sent"
        case .sendFailed: "send_failed"
        case .composeDiscarded: "compose_discarded"
        case .draftDeleted: "draft_deleted"
        case .attachmentSaved: "attachment_saved"
        case .remoteMediaLoaded: "remote_media_loaded"
        case .accountAdded: "account_added"
        case .accountReauthenticated: "account_reauthenticated"
        case .accountRemoved: "account_removed"
        case .accountSwitched: "account_switched"
        case .notificationsToggled: "notifications_toggled"
        case .mailboxColorChanged: "mailbox_color_changed"
        case .updateCheckRequested: "update_check_requested"
        case .launchFailed: "launch_failed"
        }
    }

    /// The event's properties. Every value here is a closed-enum raw value, a Bool,
    /// or a bucket — see the privacy contract at the top of this file.
    var props: [String: UsageValue] {
        switch self {
        case .viewShown(let view, let via):
            ["view": .string(view.rawValue), "via": .string(via.rawValue)]
        case .syncCompleted(let trigger, let changed):
            ["trigger": .string(trigger.rawValue), "changed": .bool(changed)]
        case .syncFailed(let kind, let trigger):
            ["kind": .string(kind.rawValue), "trigger": .string(trigger.rawValue)]
        case .messageActionPerformed(let action, let scope, let count):
            [
                "action": .string(action.rawValue),
                "scope": .string(scope.rawValue),
                "count": .string(count.rawValue),
            ]
        case .actionFailed(let action, let kind):
            ["action": .string(action.rawValue), "kind": .string(kind.rawValue)]
        case .searchRun(let scope, let results):
            ["scope": .string(scope.rawValue), "results": .string(results.rawValue)]
        case .searchFailed(let kind):
            ["kind": .string(kind.rawValue)]
        case .composeOpened(let kind):
            ["kind": .string(kind.rawValue)]
        case .draftSaved:
            [:]
        case .messageSent(let attachments, let hasCC, let hasBCC):
            [
                "attachments": .string(attachments.rawValue),
                "has_cc": .bool(hasCC),
                "has_bcc": .bool(hasBCC),
            ]
        case .sendFailed(let kind):
            ["kind": .string(kind.rawValue)]
        case .composeDiscarded, .draftDeleted, .attachmentSaved, .remoteMediaLoaded,
            .accountRemoved, .mailboxColorChanged, .updateCheckRequested:
            [:]
        case .accountAdded(let outcome, let kind), .accountReauthenticated(let outcome, let kind):
            {
                var props: [String: UsageValue] = ["outcome": .string(outcome.rawValue)]
                // `kind` is present only on `.failed` — a success has no error to
                // classify, and a cancellation is a person's choice, not a fault.
                if outcome == .failed, let kind { props["kind"] = .string(kind.rawValue) }
                return props
            }()
        case .accountSwitched(let accounts):
            ["accounts": .string(accounts.rawValue)]
        case .notificationsToggled(let enabled):
            ["enabled": .bool(enabled)]
        case .launchFailed(let kind):
            ["kind": .string(kind.rawValue)]
        }
    }

    /// The props, converted for the SDK. The only place a Herald prop becomes a
    /// ``StatsValue``.
    var statsProps: [String: StatsValue] {
        props.mapValues(\.statsValue)
    }
}
