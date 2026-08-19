import Foundation
import HeraldKit
import Testing
@testable import Herald

/// Errors are the highest-risk path in the whole feature: `MailAPIError.server`
/// carries the server's message (upstream echoes subjects and recipient addresses
/// into it), `OAuthError` carries discovery URLs and `error_description`, and
/// `OutboxError` carries the offending address and the unreadable file's URL.
///
/// Every case below is constructed with a distinctive payload, and every assertion
/// is the same: the payload does not appear anywhere in the resulting props, and the
/// kind that does appear is in the published vocabulary. This suite would fail the
/// moment anyone reached for `String(describing:)`, `logCode`, `errorDescription`
/// or `Mirror` in the mappers.
@Suite struct UsageErrorMappingTests {
    /// Distinctive enough that a substring search cannot false-negative.
    nonisolated static let secret = "SECRET-PAYLOAD-xyz"

    nonisolated static func transportFailure() -> MailAPIError.TransportFailure {
        MailAPIError.TransportFailure(NSError(
            domain: secret,
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: secret]
        ))
    }

    nonisolated static let mailErrors: [MailAPIError] = [
        .unauthorized,
        .insufficientScope(secret),
        .notFound,
        .cursorExpired,
        .server(code: secret, message: "\(secret) to alice@example.com"),
        .transport(transportFailure()),
        .decoding,
    ]

    nonisolated static let oauthErrors: [OAuthError] = [
        .discoveryFailed(url: "https://\(secret).example.com/.well-known", reason: .status),
        .registrationUnsupported,
        .registrationFailed(status: 500),
        .server(error: secret, description: "\(secret) description"),
        .stateMismatch,
        .missingAuthorizationCode,
        .reauthenticationRequired,
        .missingRefreshToken,
        .malformedTokenResponse,
        .userCancelled,
        .webAuthenticationFailed(secret),
        .unknownAccount(secret),
        .transport(transportFailure()),
    ]

    nonisolated static let outboxErrors: [OutboxError] = [
        .invalidRecipient("\(secret)@example.com"),
        .noRecipients,
        .attachmentTooLarge(bytes: 123_456_789, limit: 25_000_000),
        .draftTooLarge(bytes: 987_654_321, limit: 25_000_000),
        .tooManyAttachments(limit: 17),
        .draftConflict,
        .api(.server(code: secret, message: secret)),
        .fileUnreadable(URL(fileURLWithPath: "/tmp/\(secret).pdf")),
    ]

    // MARK: MailAPIError

    @Test(arguments: mailErrors)
    func mailErrorMapsToVocabularyAndDropsPayload(error: MailAPIError) {
        let kind = UsageMailErrorKind(error)
        #expect(UsageEventContractTests.mailErrorKinds.contains(kind.rawValue))
        expectNoLeak(in: [
            .syncFailed(kind: kind, trigger: .auto),
            .actionFailed(action: .archive, kind: kind),
            .searchFailed(kind: kind),
        ])
    }

    /// Fails if two distinct API failures ever collapse into one kind — the mapping
    /// has to stay useful, not just safe.
    @Test func mailErrorKindsAreDistinctPerCase() {
        let kinds = Self.mailErrors.map { UsageMailErrorKind($0).rawValue }
        #expect(Set(kinds).count == Self.mailErrors.count)
    }

    // MARK: OAuthError

    @Test(arguments: oauthErrors)
    func oauthErrorMapsToVocabularyAndDropsPayload(error: OAuthError) {
        let kind = UsageOAuthErrorKind(error)
        #expect(UsageEventContractTests.oauthErrorKinds.contains(kind.rawValue))
        expectNoLeak(in: [
            .accountAdded(outcome: .failed, kind: kind),
            .accountReauthenticated(outcome: .failed, kind: kind),
        ])
    }

    /// `registrationUnsupported` and `registrationFailed` deliberately share
    /// `registration`; nothing else may collapse.
    @Test func oauthErrorKindsCollapseOnlyTheRegistrationPair() {
        let kinds = Self.oauthErrors.map { UsageOAuthErrorKind($0).rawValue }
        #expect(Set(kinds).count == Self.oauthErrors.count - 1)
    }

    // MARK: OutboxError

    @Test(arguments: outboxErrors)
    func outboxErrorMapsToVocabularyAndDropsPayload(error: OutboxError) {
        let kind = UsageOutboxErrorKind(error)
        #expect(UsageOutboxErrorKind.allRawValues.contains(kind.rawValue))
        #expect(UsageEventContractTests.outboxErrorKinds.contains(kind.rawValue))
        expectNoLeak(in: [.sendFailed(kind: kind)])
    }

    /// The byte counts and limits in `attachmentTooLarge` / `draftTooLarge` /
    /// `tooManyAttachments` are file sizes — `logCode` embeds the limit, and this
    /// fails if the mapper is ever "helpfully" switched to it.
    @Test func outboxSizeErrorsCarryNoNumbers() {
        for error in [
            OutboxError.attachmentTooLarge(bytes: 123_456_789, limit: 25_000_000),
            .draftTooLarge(bytes: 987_654_321, limit: 25_000_000),
            .tooManyAttachments(limit: 17),
        ] {
            let raw = UsageOutboxErrorKind(error).rawValue
            let hasDigit = raw.contains { $0.isNumber }
            #expect(!hasDigit, "\(raw) carries a number")
        }
    }

    // MARK: The `other` fallback

    /// An error from outside the vocabulary — a `URLError`, an `NSError`, a
    /// `CancellationError` — is COUNTED as `other` rather than dropped, and
    /// carries nothing of itself. Fails both ways: if such a failure silently
    /// stops being reported (the old behaviour, which made failure rates a lie),
    /// and if any part of the foreign error's payload rides along.
    @Test func foreignErrorsMapToOtherAndCarryNoPayload() {
        let foreign: [any Error] = [
            URLError(.networkConnectionLost),
            NSError(domain: Self.secret, code: 7, userInfo: [
                NSLocalizedDescriptionKey: "\(Self.secret) at alice@example.com",
            ]),
            CancellationError(),
            OAuthError.userCancelled,  // an OAuth error is not a MailAPIError
        ]
        for error in foreign {
            #expect(UsageMailErrorKind(anyError: error) == .other)
            expectNoLeak(in: [
                .syncFailed(kind: UsageMailErrorKind(anyError: error), trigger: .auto),
                .actionFailed(action: .archive, kind: UsageMailErrorKind(anyError: error)),
                .searchFailed(kind: UsageMailErrorKind(anyError: error)),
            ])
        }
        for error in foreign.dropLast() {
            #expect(UsageOAuthErrorKind(anyError: error) == .other)
            expectNoLeak(in: [.accountAdded(outcome: .failed, kind: .other)])
        }
        // A real error of each type still classifies as itself, so the fallback
        // cannot be swallowing everything.
        #expect(UsageMailErrorKind(anyError: MailAPIError.cursorExpired) == .cursorExpired)
        #expect(UsageOAuthErrorKind(anyError: OAuthError.stateMismatch) == .stateMismatch)
    }

    /// The outbox vocabulary is derived from the mail one, so `other` has to have
    /// carried through to `api_other`. Fails if the two drift apart.
    @Test func theOutboxVocabularyIncludesApiOther() {
        #expect(UsageOutboxErrorKind.allRawValues.contains("api_other"))
        #expect(UsageOutboxErrorKind.api(.other).rawValue == "api_other")
    }

    /// An API failure keeps only the classification, behind `api_`.
    @Test func outboxAPIErrorKeepsOnlyTheMailKind() {
        #expect(UsageOutboxErrorKind(.api(.cursorExpired)).rawValue == "api_cursor_expired")
        #expect(UsageOutboxErrorKind(.api(.server(code: Self.secret, message: Self.secret)))
            .rawValue == "api_server")
    }

    // MARK: Helper

    private func expectNoLeak(in events: [UsageEvent], sourceLocation: SourceLocation = #_sourceLocation) {
        for event in events {
            for (key, value) in event.props {
                guard case .string(let string) = value else { continue }
                #expect(
                    !string.contains(Self.secret),
                    "\(event.name).\(key) leaked the error payload",
                    sourceLocation: sourceLocation
                )
                #expect(
                    !string.contains("example.com"),
                    "\(event.name).\(key) leaked a host",
                    sourceLocation: sourceLocation
                )
            }
        }
    }
}
