import Foundation
import Testing
@testable import HeraldKit

/// The manage-signatures service: the two compatibility states it must tell
/// apart, the guards that stop a guaranteed-400 request from being made, and the
/// grouping the Settings pane renders.
///
/// Every test asserts the CALL LOG as well as the outcome. "The PATCH was not
/// sent" is only assertable from the log — a `nil` return alone would also be
/// produced by a service that sent the request and threw the answer away.
@Suite struct SignatureManagementServiceTests {
    static let epoch = Date(timeIntervalSince1970: 0)

    static func signature(
        id: String,
        name: String,
        scope: SignatureScope = .mailbox,
        scopeID: String = "mbx_support",
        scopeLabel: String = "support@example.com",
        html: String = "<p>Hi</p>",
        isDefault: Bool = false
    ) -> Signature {
        Signature(
            id: id,
            name: name,
            html: html,
            text: html,
            scope: scope,
            scopeID: scopeID,
            scopeLabel: scopeLabel,
            isDefault: isDefault,
            createdAt: epoch,
            updatedAt: epoch
        )
    }

    static let scope = SignatureScopeRef(type: .mailbox, id: "mbx_support")

    // MARK: - The two compatibility states

    /// The whole point of the feature's error handling: an account that consented
    /// before `signatures:manage` existed and a server that predates the routes
    /// need DIFFERENT screens — one wants a fresh sign-in, the other a newer
    /// server. Collapsing them into one "error" is the bug this guards.
    @Test("403 insufficient_scope and 404 map to distinct, non-retryable states")
    func compatibilityStatesAreDistinct() async throws {
        let api = FakeMailAPIClient()
        let service = SignatureManagementService(api: api)

        await api.setSignatureManagementFailure(.insufficientScope("signatures:manage"))
        await #expect(throws: SignatureManagementError.notAuthorized) { try await service.list() }

        await api.setSignatureManagementFailure(.notFound)
        await #expect(throws: SignatureManagementError.unsupportedByServer) { try await service.list() }

        // Neither offers a retry: the token can never gain the scope, and the
        // server will not get newer while the pane is open.
        #expect(SignatureManagementError.notAuthorized.isRetryable == false)
        #expect(SignatureManagementError.unsupportedByServer.isRetryable == false)
    }

    /// A 404 means something different on a single-id route: the collection route
    /// always answers 200 on a 1.4.2 server, but `DELETE /signatures/{id}` answers
    /// 404 for a row that is simply gone. Reporting "server too old" there would
    /// hide a perfectly working server behind a compatibility screen.
    @Test("404 on a single-id write is a missing row, not a missing route")
    func notFoundOnWriteIsNotACompatibilityState() async throws {
        let api = FakeMailAPIClient()
        let service = SignatureManagementService(api: api)
        // No failure armed: the fake 404s because no such signature exists.
        await #expect(throws: SignatureManagementError.signatureGone) {
            try await service.delete(id: "sig-missing")
        }
        await #expect(throws: SignatureManagementError.signatureGone) {
            try await service.update(id: "sig-missing", with: UpdateSignatureInput(name: "New"))
        }
    }

    // MARK: - Guards

    /// A body with no fields is a guaranteed 400 `SIGNATURE_INVALID` upstream
    /// (the spec's `anyOf` over `required`, which the generator cannot model).
    /// Fails if the request is made at all.
    @Test("An empty PATCH is never sent")
    func emptyUpdateIsNotSent() async throws {
        let api = FakeMailAPIClient()
        await api.setManageableSignatures([Self.signature(id: "sig-1", name: "Work")])
        let service = SignatureManagementService(api: api)

        let result = try await service.update(id: "sig-1", with: UpdateSignatureInput())

        #expect(result == nil)
        let calls = await api.calls
        #expect(calls.isEmpty, "An empty PATCH body must not reach the network")
    }

    /// `name` is `minLength: 1` in the spec. Blocked client-side so it is a field
    /// complaint on the sheet, not a round trip that comes back 400.
    @Test("An empty or whitespace-only name is blocked before the request")
    func emptyNameIsBlockedClientSide() async throws {
        let api = FakeMailAPIClient()
        let service = SignatureManagementService(api: api)

        await #expect(throws: SignatureManagementError.nameRequired) {
            try await service.create(
                CreateSignatureInput(name: "   \n ", html: "<p>Hi</p>", scope: Self.scope)
            )
        }
        await #expect(throws: SignatureManagementError.nameRequired) {
            try await service.update(id: "sig-1", with: UpdateSignatureInput(name: ""))
        }

        let calls = await api.calls
        #expect(calls.isEmpty, "A nameless signature must not reach the network")
    }

    @Test("Name and HTML length limits are enforced before the request")
    func lengthLimitsAreEnforcedClientSide() async throws {
        let api = FakeMailAPIClient()
        let service = SignatureManagementService(api: api)

        await #expect(throws: SignatureManagementError.nameTooLong) {
            try await service.create(
                CreateSignatureInput(
                    name: String(repeating: "a", count: SignatureManagementService.maxNameLength + 1),
                    html: "<p>Hi</p>",
                    scope: Self.scope
                )
            )
        }
        await #expect(throws: SignatureManagementError.htmlTooLarge) {
            try await service.create(
                CreateSignatureInput(
                    name: "Work",
                    html: String(repeating: "a", count: SignatureManagementService.maxHTMLLength + 1),
                    scope: Self.scope
                )
            )
        }
        let calls = await api.calls
        #expect(calls.isEmpty)
    }

    // MARK: - Round trips

    @Test("A create reaches the server and is listed afterwards")
    func createIsListed() async throws {
        let api = FakeMailAPIClient()
        let service = SignatureManagementService(api: api)

        let created = try await service.create(
            CreateSignatureInput(name: "Work", html: "<p>Ada</p>", scope: Self.scope, isDefault: true)
        )
        #expect(created.name == "Work")
        #expect(created.isDefault)

        let listed = try await service.list()
        #expect(listed.map(\.id) == [created.id])
    }

    /// The delete half of "removes from the list on success". The pane re-lists
    /// after a mutation rather than patching its array, so the server's answer is
    /// the thing that must change.
    @Test("A successful delete removes the signature from the next list")
    func deleteRemovesOnSuccess() async throws {
        let api = FakeMailAPIClient()
        await api.setManageableSignatures([
            Self.signature(id: "sig-1", name: "Work"),
            Self.signature(id: "sig-2", name: "Personal"),
        ])
        let service = SignatureManagementService(api: api)

        try await service.delete(id: "sig-1")

        let listed = try await service.list()
        #expect(listed.map(\.id) == ["sig-2"])
    }

    /// The failure half: a delete that the server refused must leave the row
    /// there. A pane that removed it optimistically would show a deletion that
    /// did not happen, and the next refresh would make the row reappear.
    @Test("A failed delete leaves the signature in the list")
    func deleteKeepsOnFailure() async throws {
        let api = FakeMailAPIClient()
        await api.setManageableSignatures([Self.signature(id: "sig-1", name: "Work")])
        await api.setSignatureManagementFailure(.server(code: "SIGNATURE_FORBIDDEN", message: "No"))
        let service = SignatureManagementService(api: api)

        await #expect(throws: SignatureManagementError.scopeForbidden) {
            try await service.delete(id: "sig-1")
        }

        await api.setSignatureManagementFailure(nil)
        let listed = try await service.list()
        #expect(listed.map(\.id) == ["sig-1"])
    }

    @Test("A name collision inside one scope is reported as such, not as a generic failure")
    func duplicateNameIsDistinct() async throws {
        let api = FakeMailAPIClient()
        await api.setSignatureManagementFailure(
            .server(code: "SIGNATURE_NAME_CONFLICT", message: "Duplicate")
        )
        let service = SignatureManagementService(api: api)

        await #expect(throws: SignatureManagementError.duplicateName) {
            try await service.create(
                CreateSignatureInput(name: "Work", html: "<p>Hi</p>", scope: Self.scope)
            )
        }
    }

    // MARK: - Grouping

    /// Ordering must be TOTAL and independent of the server's, or the list
    /// reshuffles under the cursor between two refreshes.
    @Test("Signatures group by scope, ordered personal → mailbox → domain")
    func groupsByScope() {
        let signatures = [
            Self.signature(id: "d1", name: "Legal", scope: .domain, scopeID: "dom_1", scopeLabel: "example.com"),
            Self.signature(id: "m2", name: "Alpha", scope: .mailbox, scopeID: "mbx_2", scopeLabel: "sales@example.com"),
            Self.signature(id: "u1", name: "Ada", scope: .user, scopeID: "usr_1", scopeLabel: "Ada"),
            Self.signature(id: "m1", name: "Zulu", scope: .mailbox, scopeID: "mbx_1", scopeLabel: "help@example.com"),
            Self.signature(id: "m1b", name: "Alpha", scope: .mailbox, scopeID: "mbx_1", scopeLabel: "help@example.com"),
        ]

        let groups = SignatureScopeGroup.group(signatures)

        #expect(groups.map(\.scope) == [.user, .mailbox, .mailbox, .domain])
        // Within a kind, by label: help@ before sales@.
        #expect(groups.map(\.label) == ["Ada", "help@example.com", "sales@example.com", "example.com"])
        // Two signatures of one mailbox land in ONE group, sorted by name.
        #expect(groups[1].signatures.map(\.name) == ["Alpha", "Zulu"])
        // Ids are unique across kinds that could share a raw scope id.
        #expect(Set(groups.map(\.id)).count == groups.count)
    }

    /// Grouping the same list twice must give the same answer — `Dictionary`
    /// iteration order is not stable across runs, so the sort is what makes this
    /// true.
    @Test("Grouping is deterministic")
    func groupingIsDeterministic() {
        let signatures = (1...12).map {
            Self.signature(
                id: "sig-\($0)",
                name: "Name \($0)",
                scope: .mailbox,
                scopeID: "mbx_\($0 % 4)",
                scopeLabel: "box\($0 % 4)@example.com"
            )
        }
        let first = SignatureScopeGroup.group(signatures)
        let second = SignatureScopeGroup.group(signatures.shuffled())
        #expect(first == second)
    }

    @Test("An empty list groups to nothing rather than an empty section")
    func emptyGrouping() {
        #expect(SignatureScopeGroup.group([]).isEmpty)
    }
}
