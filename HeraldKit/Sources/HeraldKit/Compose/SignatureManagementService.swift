import Foundation

/// What went wrong managing a signature, as the Settings pane needs to tell it
/// apart. Deliberately NOT a passthrough of ``MailAPIError``: the pane draws
/// three structurally different screens (re-sign-in, server too old, retry) and
/// the decision of which one belongs here, next to the semantics, rather than in
/// a view.
public nonisolated enum SignatureManagementError: Error, Sendable, Hashable {
    /// 403 `insufficient_scope`. The account consented BEFORE `signatures:manage`
    /// existed, so its token can never carry the scope — only a fresh sign-in
    /// fixes it. Not retryable.
    case notAuthorized
    /// 404 on `GET /signatures/manage`, which on a 1.4.2+ server always answers
    /// 200 with a (possibly empty) list. A 404 therefore means the ROUTE is
    /// absent: the server predates 1.4.2. Not retryable.
    case unsupportedByServer
    /// 404 on a write to one id. Ambiguous at the HTTP level (missing route vs
    /// `SIGNATURE_NOT_FOUND`), so the caller re-lists rather than guessing: a
    /// genuinely old server then reports ``unsupportedByServer`` from the list.
    case signatureGone
    /// 403 `SIGNATURE_FORBIDDEN` — the scope is real but this principal may not
    /// manage it (not a mailbox manager, or not an admin for a domain). A
    /// different thing from ``notAuthorized``: signing in again changes nothing.
    case scopeForbidden
    /// 409 `SIGNATURE_NAME_CONFLICT` — names are unique per scope.
    case duplicateName
    /// Client-side guards, so an empty or oversized field never becomes a round
    /// trip that comes back 400.
    case nameRequired
    case nameTooLong
    case htmlTooLarge
    /// Anything else, kept whole so the pane can show the server's message.
    case api(MailAPIError)

    /// Whether offering a "Try Again" button is honest. The two compatibility
    /// states and the client-side guards are permanent for this account/server,
    /// so a retry there would just redraw the same screen.
    public var isRetryable: Bool {
        switch self {
        case .notAuthorized, .unsupportedByServer, .nameRequired, .nameTooLong, .htmlTooLarge:
            false
        case .signatureGone, .scopeForbidden, .duplicateName, .api:
            true
        }
    }
}

nonisolated extension SignatureManagementError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "This account was signed in before signature management existed — sign in again to manage signatures."
        case .unsupportedByServer:
            "This server is too old to manage signatures. It needs HQBase 1.4.2 or newer."
        case .signatureGone:
            "That signature no longer exists."
        case .scopeForbidden:
            "You do not have permission to manage signatures for that mailbox or domain."
        case .duplicateName:
            "That scope already has a signature with this name."
        case .nameRequired:
            "Give the signature a name."
        case .nameTooLong:
            "Signature names are limited to \(SignatureManagementService.maxNameLength) characters."
        case .htmlTooLarge:
            "This signature is too large. The limit is \(SignatureManagementService.maxHTMLLength) characters."
        case .api(let error):
            error.errorDescription
        }
    }
}

/// The Settings pane's whole dependency on the network, so it can be driven by a
/// fake in the app-hosted tests.
///
/// `nonisolated` because ``SignatureManagementService`` is an actor: an actor
/// cannot conform to a global-actor-isolated protocol.
public nonisolated protocol SignatureManaging: Sendable {
    /// Every signature this principal may EDIT, across scopes.
    func list() async throws(SignatureManagementError) -> [Signature]
    func create(_ input: CreateSignatureInput) async throws(SignatureManagementError) -> Signature
    /// `nil` when `input` says nothing — see ``SignatureManagementService/update(id:with:)``.
    func update(id: String, with input: UpdateSignatureInput) async throws(SignatureManagementError) -> Signature?
    func delete(id: String) async throws(SignatureManagementError)
}

extension SignatureManagementService: SignatureManaging {}

/// Create/read/update/delete over the `signatures:manage` routes (upstream
/// 1.4.2+).
///
/// An actor for the same reason ``OutboxService`` is one: this is off-main
/// network work, and nothing here needs the main actor.
///
/// It deliberately does NOT cache. The list is short, the pane is modal-ish, and
/// a stale cache here would show a signature the server has already rejected a
/// duplicate name against. Every mutation is followed by a fresh list.
public actor SignatureManagementService {
    /// `CreateSignatureInput.name` is `minLength: 1, maxLength: 200` in the spec.
    public static let maxNameLength = 200
    /// `CreateSignatureInput.html` is `maxLength: 400000` in the spec.
    public static let maxHTMLLength = 400_000

    private let api: any MailAPIClient

    public init(api: any MailAPIClient) {
        self.api = api
    }

    public func list() async throws(SignatureManagementError) -> [Signature] {
        do {
            return try await api.listManageableSignatures()
        } catch let error as MailAPIError {
            // A 1.4.2+ server answers this route 200 with a list, empty or not,
            // so a 404 can only be a missing route.
            throw Self.map(error, notFoundMeans: .unsupportedByServer)
        } catch {
            throw .api(.transport(.init(error)))
        }
    }

    public func create(_ input: CreateSignatureInput) async throws(SignatureManagementError) -> Signature {
        try Self.validate(name: input.name, html: input.html)
        do {
            return try await api.createSignature(input)
        } catch let error as MailAPIError {
            // POST to the collection: a 404 is again the absent route.
            throw Self.map(error, notFoundMeans: .unsupportedByServer)
        } catch {
            throw .api(.transport(.init(error)))
        }
    }

    /// Applies only the fields `input` actually carries.
    ///
    /// - Returns: `nil` when `input` is empty. The server REQUIRES at least one
    ///   of name/html/isDefault and answers 400 `SIGNATURE_INVALID` otherwise, so
    ///   a "Save" on a sheet nothing was typed into must not become a request at
    ///   all — the caller treats `nil` as "saved, nothing to do".
    public func update(
        id: String,
        with input: UpdateSignatureInput
    ) async throws(SignatureManagementError) -> Signature? {
        guard !input.isEmpty else { return nil }
        try Self.validate(name: input.name, html: input.html)
        do {
            return try await api.updateSignature(id: id, with: input)
        } catch let error as MailAPIError {
            throw Self.map(error, notFoundMeans: .signatureGone)
        } catch {
            throw .api(.transport(.init(error)))
        }
    }

    public func delete(id: String) async throws(SignatureManagementError) {
        do {
            try await api.deleteSignature(id: id)
        } catch let error as MailAPIError {
            throw Self.map(error, notFoundMeans: .signatureGone)
        } catch {
            throw .api(.transport(.init(error)))
        }
    }

    // MARK: - Guards

    /// The two length rules the spec states, checked before the request so a
    /// blank name is a field-level complaint rather than a 400 round trip.
    /// A `nil` field is one the caller is not changing, so it is not checked.
    static func validate(name: String?, html: String?) throws(SignatureManagementError) {
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw .nameRequired }
            guard trimmed.count <= maxNameLength else { throw .nameTooLong }
        }
        if let html, html.count > maxHTMLLength { throw .htmlTooLarge }
    }

    /// The single place HTTP semantics become pane states.
    ///
    /// `notFoundMeans` is the caller's disambiguation of 404, which the HTTP
    /// layer cannot make: on a collection route it is a missing route, on a
    /// single-id route it is a missing row.
    static func map(
        _ error: MailAPIError,
        notFoundMeans notFound: SignatureManagementError
    ) -> SignatureManagementError {
        switch error {
        case .insufficientScope:
            .notAuthorized
        case .notFound:
            notFound
        case .server(let code, _) where code == "SIGNATURE_FORBIDDEN":
            .scopeForbidden
        case .server(let code, _) where code == "SIGNATURE_NAME_CONFLICT":
            .duplicateName
        default:
            .api(error)
        }
    }
}

/// One scope's signatures, for the grouped list.
///
/// A struct rather than a dictionary because the pane renders the scopes in a
/// fixed order (personal, then mailboxes, then domains) and a dictionary has
/// none — the same reason `AppEnvironment` keeps `accountIDs` beside `graphs`.
public nonisolated struct SignatureScopeGroup: Sendable, Hashable, Identifiable {
    public let scope: SignatureScope
    public let scopeID: String
    /// The server's own label for the scope (mailbox address, or domain name).
    public let label: String
    public let signatures: [Signature]

    /// Unique across the whole list: two scopes of different kinds could in
    /// principle share an id.
    public var id: String { "\(scope.rawValue):\(scopeID)" }

    public init(scope: SignatureScope, scopeID: String, label: String, signatures: [Signature]) {
        self.scope = scope
        self.scopeID = scopeID
        self.label = label
        self.signatures = signatures
    }

    /// Groups a flat `GET /signatures/manage` answer.
    ///
    /// Ordering is total and does not depend on the server's: scope kind first
    /// (personal, mailbox, domain — the precedence the server resolves an
    /// automatic pick in), then label, then signature name. A list that
    /// reordered itself between two refreshes would move rows under the cursor.
    public static func group(_ signatures: [Signature]) -> [SignatureScopeGroup] {
        let buckets = Dictionary(grouping: signatures) { ScopeKey($0) }
        return buckets
            .map { key, values in
                SignatureScopeGroup(
                    scope: key.scope,
                    scopeID: key.scopeID,
                    label: key.label,
                    signatures: values.sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                )
            }
            .sorted { lhs, rhs in
                guard lhs.scope == rhs.scope else { return lhs.scope.order < rhs.scope.order }
                let byLabel = lhs.label.localizedStandardCompare(rhs.label)
                return byLabel == .orderedSame ? lhs.scopeID < rhs.scopeID : byLabel == .orderedAscending
            }
    }

    /// Identity of a bucket. The label rides along so grouping never needs a
    /// second pass to find one.
    private struct ScopeKey: Hashable {
        let scope: SignatureScope
        let scopeID: String
        let label: String

        init(_ signature: Signature) {
            scope = signature.scope
            scopeID = signature.scopeID
            label = signature.scopeLabel
        }
    }
}

nonisolated extension SignatureScope {
    /// Display order, matching the server's resolution precedence for an
    /// automatic pick (`automaticSignature`): mailbox, user, domain — shown here
    /// most-personal first.
    var order: Int {
        switch self {
        case .user: 0
        case .mailbox: 1
        case .domain: 2
        }
    }

    /// Section heading prefix, e.g. "Personal" / "Mailbox" / "Domain".
    public var displayName: String {
        switch self {
        case .user: "Personal"
        case .mailbox: "Mailbox"
        case .domain: "Domain"
        }
    }
}
