import Foundation
import HeraldKit
import Testing
@testable import Herald

/// Settings ▸ Signatures: which screen each failure draws, how the scope picker
/// is reconstructed from cached mailboxes, and what a save or delete does to the
/// list and to open compose windows.
@MainActor
@Suite struct SignatureSettingsTests {
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

    static func mailbox(
        id: String,
        address: String,
        domainID: String,
        accessLevel: MailboxAccessLevel? = .manager
    ) -> Mailbox {
        Mailbox(
            id: id,
            address: address,
            addresses: [
                MailboxAddress(
                    id: "adr_\(id)",
                    mailboxID: id,
                    mailDomainID: domainID,
                    address: address,
                    displayName: "",
                    receiveEnabled: true,
                    sendEnabled: true,
                    isPrimary: true
                )
            ],
            displayName: "",
            isActive: true,
            accessLevel: accessLevel,
            createdAt: epoch,
            updatedAt: epoch
        )
    }

    static func model(
        _ service: FakeSignatureManaging,
        mailboxes: [Mailbox] = [],
        didMutate: @escaping @MainActor () -> Void = {}
    ) -> SignatureSettingsModel {
        SignatureSettingsModel(
            service: service,
            mailboxes: { mailboxes },
            didMutate: didMutate
        )
    }

    // MARK: - Load states

    /// The two compatibility failures must reach the pane as DIFFERENT states:
    /// one offers "Sign In Again", the other says the server is too old and
    /// offers nothing. A shared `.failed` would put a useless retry on both.
    @Test("403 and 404 draw the two distinct compatibility screens")
    func loadCompatibilityStates() async {
        let scopeDenied = FakeSignatureManaging(listResult: .failure(.notAuthorized))
        let denied = Self.model(scopeDenied)
        await denied.load()
        #expect(denied.state == .needsReauthorization)

        let old = FakeSignatureManaging(listResult: .failure(.unsupportedByServer))
        let oldModel = Self.model(old)
        await oldModel.load()
        #expect(oldModel.state == .unsupportedByServer)
    }

    @Test("Any other failure is a retryable error state carrying the message")
    func loadGenericFailure() async {
        let service = FakeSignatureManaging(
            listResult: .failure(.api(.server(code: "BOOM", message: "Server exploded")))
        )
        let model = Self.model(service)
        await model.load()

        guard case .failed(let message) = model.state else {
            Issue.record("Expected .failed, got \(model.state)")
            return
        }
        #expect(message == "Server exploded")
    }

    /// An empty list is not an error: the account simply has no signatures yet.
    @Test("An empty list is the ready state with no groups")
    func loadEmpty() async {
        let model = Self.model(FakeSignatureManaging(listResult: .success([])))
        await model.load()
        #expect(model.state == .ready)
        #expect(model.groups.isEmpty)
    }

    @Test("A loaded list is grouped by scope")
    func loadGroups() async {
        let service = FakeSignatureManaging(listResult: .success([
            Self.signature(id: "sig-1", name: "Work"),
            Self.signature(id: "sig-2", name: "Ada", scope: .user, scopeID: "usr_1", scopeLabel: "Ada"),
        ]))
        let model = Self.model(service)
        await model.load()

        #expect(model.state == .ready)
        #expect(model.groups.map(\.scope) == [.user, .mailbox])
    }

    // MARK: - Scope options

    /// Upstream requires `scope.id == actor.id` for a personal signature and no
    /// route tells a client its own user id. Offering "Personal" without one
    /// could only ever produce a 403, so it is offered only once an existing
    /// user-scoped signature has revealed the id.
    @Test("Personal scope appears only once a user-scoped signature reveals the user id")
    func personalScopeNeedsAKnownUserID() {
        let mailboxes = [Self.mailbox(id: "mbx_1", address: "help@example.com", domainID: "dom_1")]

        let withoutPersonal = SignatureSettingsModel.scopeOptions(mailboxes: mailboxes, existing: [])
        #expect(withoutPersonal.contains { $0.scope == .user } == false)

        let withPersonal = SignatureSettingsModel.scopeOptions(
            mailboxes: mailboxes,
            existing: [Self.signature(id: "u", name: "Ada", scope: .user, scopeID: "usr_7", scopeLabel: "Ada")]
        )
        let personal = withPersonal.first { $0.scope == .user }
        #expect(personal?.ref.id == "usr_7")
    }

    /// A mailbox the user can only READ is not one they can file a signature
    /// under; an unreported level is offered because the server, not the client,
    /// is the authority and hiding a usable scope is the worse failure.
    @Test("Read-only mailboxes are not offered; unreported access levels are")
    func mailboxScopesFilterByAccess() {
        let options = SignatureSettingsModel.scopeOptions(
            mailboxes: [
                Self.mailbox(id: "mbx_read", address: "read@example.com", domainID: "dom_1", accessLevel: .read),
                Self.mailbox(id: "mbx_agent", address: "agent@example.com", domainID: "dom_1", accessLevel: .agent),
                Self.mailbox(id: "mbx_mgr", address: "mgr@example.com", domainID: "dom_1", accessLevel: .manager),
                Self.mailbox(id: "mbx_nil", address: "nil@example.com", domainID: "dom_1", accessLevel: nil),
            ],
            existing: []
        )
        let mailboxIDs = options.filter { $0.scope == .mailbox }.map(\.ref.id)
        #expect(mailboxIDs == ["mbx_mgr", "mbx_nil"])
    }

    /// Two mailboxes on one domain must not produce two identical domain rows.
    @Test("Domain scopes are deduplicated and labelled by domain name")
    func domainScopesAreDeduplicated() {
        let options = SignatureSettingsModel.scopeOptions(
            mailboxes: [
                Self.mailbox(id: "mbx_1", address: "help@example.com", domainID: "dom_1"),
                Self.mailbox(id: "mbx_2", address: "sales@example.com", domainID: "dom_1"),
                Self.mailbox(id: "mbx_3", address: "hi@other.test", domainID: "dom_2"),
            ],
            existing: []
        )
        let domains = options.filter { $0.scope == .domain }
        #expect(domains.map(\.ref.id) == ["dom_1", "dom_2"])
        #expect(domains.map(\.label) == ["example.com", "other.test"])
    }

    // MARK: - Editing

    /// A sheet opened and saved without a single edit must make NO request: the
    /// server answers 400 `SIGNATURE_INVALID` to a PATCH body that says nothing.
    @Test("Saving an unchanged signature sends no PATCH")
    func unchangedSaveSendsNothing() async {
        let existing = Self.signature(id: "sig-1", name: "Work", html: "<p>Hi</p>", isDefault: true)
        let service = FakeSignatureManaging(listResult: .success([existing]))
        let model = Self.model(service)
        await model.load()

        model.beginEdit(existing)
        await model.save()

        #expect(service.updates.isEmpty, "An untouched sheet must not reach the network")
        #expect(model.editor == nil, "The sheet still closes — nothing needed saving")
    }

    /// Only the fields that changed go in the body, so saving a renamed signature
    /// cannot also re-send (and re-sanitise) HTML the user never touched.
    @Test("A PATCH carries only the changed fields")
    func patchCarriesOnlyChanges() async {
        let existing = Self.signature(id: "sig-1", name: "Work", html: "<p>Hi</p>")
        let service = FakeSignatureManaging(listResult: .success([existing]))
        let model = Self.model(service)
        await model.load()

        model.beginEdit(existing)
        model.editor?.name = "Work Updated"
        await model.save()

        #expect(service.updates.count == 1)
        let input = try? #require(service.updates.first?.input)
        #expect(input?.name == "Work Updated")
        #expect(input?.html == nil)
        #expect(input?.isDefault == nil)
    }

    /// The scope is fixed on an existing signature: `PATCH /signatures/{id}` has
    /// no scope field, so a signature cannot be moved between scopes.
    @Test("Editing an existing signature keeps its scope")
    func editingKeepsScope() async {
        let existing = Self.signature(id: "sig-1", name: "Work")
        let model = Self.model(FakeSignatureManaging(listResult: .success([existing])))
        await model.load()

        model.beginEdit(existing)
        #expect(model.editor?.scope == SignatureScopeRef(type: .mailbox, id: "mbx_support"))
        #expect(model.editor?.isEditingExisting == true)
    }

    /// A blank name never becomes a request: Save is not offered for one, and the
    /// service refuses it besides.
    @Test("A blank name blocks the save client-side")
    func blankNameIsBlocked() async {
        let service = FakeSignatureManaging(listResult: .success([]))
        let model = Self.model(
            service,
            mailboxes: [Self.mailbox(id: "mbx_1", address: "help@example.com", domainID: "dom_1")]
        )
        await model.load()

        model.beginCreate()
        model.editor?.name = "   "
        #expect(model.editor?.canSave == false)

        await model.save()
        #expect(service.creates.isEmpty, "A nameless signature must not reach the network")
        #expect(model.editor != nil, "The sheet stays up so nothing typed is lost")
        #expect(model.editor?.fieldError != nil)
    }

    /// A rejected save keeps the sheet up with what the user typed, rather than
    /// closing and losing it.
    @Test("A rejected create keeps the sheet and its contents")
    func rejectedCreateKeepsSheet() async {
        let service = FakeSignatureManaging(listResult: .success([]))
        service.createResult = .failure(.duplicateName)
        let model = Self.model(
            service,
            mailboxes: [Self.mailbox(id: "mbx_1", address: "help@example.com", domainID: "dom_1")]
        )
        await model.load()

        model.beginCreate()
        model.editor?.name = "Work"
        model.editor?.html = "<p>Ada</p>"
        await model.save()

        #expect(model.editor?.name == "Work")
        #expect(model.editor?.html == "<p>Ada</p>")
        #expect(model.editor?.fieldError != nil)
    }

    // MARK: - Deleting

    @Test("A successful delete removes the row and refreshes compose candidates")
    func deleteRemovesOnSuccess() async {
        let service = FakeSignatureManaging(listResult: .success([
            Self.signature(id: "sig-1", name: "Work"),
            Self.signature(id: "sig-2", name: "Other", scopeID: "mbx_support"),
        ]))
        var mutations = 0
        let model = Self.model(service, didMutate: { mutations += 1 })
        await model.load()

        // The fake's list is what the re-list returns, so the deletion has to
        // reach it for the row to disappear.
        service.listResult = .success([Self.signature(id: "sig-2", name: "Other")])
        model.pendingDeletion = Self.signature(id: "sig-1", name: "Work")
        await model.confirmDeletion()

        #expect(model.groups.flatMap(\.signatures).map(\.id) == ["sig-2"])
        #expect(model.actionError == nil)
        // An open compose window must refetch, or it keeps offering a signature
        // that no longer exists.
        #expect(mutations == 1)
    }

    /// The row must stay when the server refused: removing it would show a
    /// deletion that did not happen, and the next refresh would bring it back.
    @Test("A failed delete keeps the row and surfaces the reason")
    func deleteKeepsOnFailure() async {
        let service = FakeSignatureManaging(listResult: .success([
            Self.signature(id: "sig-1", name: "Work")
        ]))
        service.deleteResult = .failure(.scopeForbidden)
        var mutations = 0
        let model = Self.model(service, didMutate: { mutations += 1 })
        await model.load()

        model.pendingDeletion = Self.signature(id: "sig-1", name: "Work")
        await model.confirmDeletion()

        #expect(model.groups.flatMap(\.signatures).map(\.id) == ["sig-1"])
        #expect(model.actionError != nil)
        #expect(mutations == 0, "Nothing changed server-side, so nothing must refetch")
    }

    @Test("Cancelling the confirmation deletes nothing")
    func cancelDeletion() async {
        let service = FakeSignatureManaging(listResult: .success([
            Self.signature(id: "sig-1", name: "Work")
        ]))
        let model = Self.model(service)
        await model.load()

        model.pendingDeletion = Self.signature(id: "sig-1", name: "Work")
        model.cancelDeletion()

        #expect(model.pendingDeletion == nil)
        #expect(service.deletes.isEmpty)
    }

    // MARK: - Compose invalidation

    @Test("A successful create refreshes compose candidates")
    func createRefreshesCandidates() async {
        let service = FakeSignatureManaging(listResult: .success([]))
        var mutations = 0
        let model = Self.model(
            service,
            mailboxes: [Self.mailbox(id: "mbx_1", address: "help@example.com", domainID: "dom_1")],
            didMutate: { mutations += 1 }
        )
        await model.load()

        model.beginCreate()
        model.editor?.name = "Work"
        model.editor?.html = "<p>Ada</p>"
        await model.save()

        #expect(service.creates.count == 1)
        #expect(mutations == 1)
    }
}

/// Scripted ``SignatureManaging`` that records every call.
///
/// A class, not an actor: the model is `@MainActor` and every call here is
/// immediate, so the tests read as straight-line code. `@unchecked Sendable` is
/// sound for the same reason — nothing here is ever touched off the main actor.
final class FakeSignatureManaging: SignatureManaging, @unchecked Sendable {
    var listResult: Result<[Signature], SignatureManagementError>
    /// `nil` means "echo back a signature built from the input", which is what a
    /// server that accepted the create would do.
    var createResult: Result<Signature, SignatureManagementError>?
    var updateResult: Result<Signature?, SignatureManagementError>?
    var deleteResult: Result<Void, SignatureManagementError> = .success(())

    private(set) var creates: [CreateSignatureInput] = []
    private(set) var updates: [(id: String, input: UpdateSignatureInput)] = []
    private(set) var deletes: [String] = []

    init(listResult: Result<[Signature], SignatureManagementError> = .success([])) {
        self.listResult = listResult
    }

    func list() async throws(SignatureManagementError) -> [Signature] {
        try listResult.get()
    }

    func create(_ input: CreateSignatureInput) async throws(SignatureManagementError) -> Signature {
        // Mirrors the real service's client-side guard (its own `validate` is
        // internal to HeraldKit), so "the model never called" and "the service
        // refused it" stay distinguishable in these tests.
        try Self.requireName(input.name)
        creates.append(input)
        if let createResult { return try createResult.get() }
        return Signature(
            id: "sig-new",
            name: input.name,
            html: input.html,
            text: input.html,
            scope: input.scope.type,
            scopeID: input.scope.id,
            scopeLabel: input.scope.id,
            isDefault: input.isDefault ?? false,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func update(
        id: String,
        with input: UpdateSignatureInput
    ) async throws(SignatureManagementError) -> Signature? {
        // Mirrors the real service: an empty body is never a request, so it is
        // never recorded either.
        guard !input.isEmpty else { return nil }
        try input.name.map(Self.requireName)
        updates.append((id, input))
        if let updateResult { return try updateResult.get() }
        return nil
    }

    /// The one guard these tests depend on: `name` is `minLength: 1` upstream.
    static func requireName(_ name: String) throws(SignatureManagementError) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .nameRequired
        }
    }

    func delete(id: String) async throws(SignatureManagementError) {
        deletes.append(id)
        try deleteResult.get()
    }
}
