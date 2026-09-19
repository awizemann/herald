import Foundation
import HeraldKit
import OSLog

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "SignatureSettings")

/// A scope the user can put a NEW signature in, with the label to offer it under.
///
/// Derived, not fetched: `GET /signatures/manage` answers a bare `Signature[]`
/// and there is no "what may I manage" route, so the options are reconstructed
/// from the cached mailboxes. The server is still the authority — picking a scope
/// it refuses comes back as ``SignatureManagementError/scopeForbidden``.
nonisolated struct SignatureScopeOption: Sendable, Hashable, Identifiable {
    let ref: SignatureScopeRef
    let label: String

    var id: String { "\(ref.type.rawValue):\(ref.id)" }
    var scope: SignatureScope { ref.type }
}

/// The Settings ▸ Signatures pane's whole behaviour, out of the view so it can be
/// tested without a window.
@MainActor
@Observable
final class SignatureSettingsModel {
    /// What the pane is showing. The two compatibility states are structurally
    /// different screens, not error strings, because neither offers a retry —
    /// one wants a fresh sign-in and the other wants a newer server.
    enum State: Equatable {
        case loading
        /// Loaded. Empty ``groups`` is the "no signatures yet" screen.
        case ready
        /// 403 `insufficient_scope`: consented before the feature shipped.
        case needsReauthorization
        /// 404 on the list route: server predates 1.4.2.
        case unsupportedByServer
        /// Anything else, with a retry.
        case failed(String)
    }

    private let service: any SignatureManaging
    /// Cached mailboxes, for deriving the scope picker's options. Re-read on
    /// every load so a mailbox that arrived since is offered.
    private let mailboxes: @MainActor () -> [Mailbox]
    /// Bumped after any successful mutation so open compose windows refetch
    /// their candidate list — a signature renamed here is otherwise still shown
    /// under its old name by a composer that is already open.
    private let didMutate: @MainActor () -> Void

    private(set) var state: State = .loading
    private(set) var groups: [SignatureScopeGroup] = []
    private(set) var scopeOptions: [SignatureScopeOption] = []
    /// The create/edit sheet, or `nil` when none is up.
    var editor: SignatureEditor?
    /// The signature the delete confirmation is about.
    var pendingDeletion: Signature?
    /// A failure from a MUTATION (not the load), shown as an inline banner so the
    /// list stays on screen and the row the user was working on is still there.
    private(set) var actionError: String?

    init(
        service: any SignatureManaging,
        mailboxes: @escaping @MainActor () -> [Mailbox],
        didMutate: @escaping @MainActor () -> Void = {}
    ) {
        self.service = service
        self.mailboxes = mailboxes
        self.didMutate = didMutate
    }

    // MARK: - Loading

    func load() async {
        // Only the FIRST load shows the spinner. A refresh after a mutation keeps
        // the list on screen, so saving a signature does not blank the pane.
        if groups.isEmpty, state != .ready { state = .loading }
        do {
            let signatures = try await service.list()
            groups = SignatureScopeGroup.group(signatures)
            scopeOptions = Self.scopeOptions(mailboxes: mailboxes(), existing: signatures)
            state = .ready
        } catch {
            groups = []
            scopeOptions = []
            state = Self.state(for: error)
            logger.error("Signature list failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Which screen a load failure draws.
    static func state(for error: SignatureManagementError) -> State {
        switch error {
        case .notAuthorized: .needsReauthorization
        case .unsupportedByServer: .unsupportedByServer
        default: .failed(error.localizedDescription)
        }
    }

    // MARK: - Scope options

    /// The scopes a new signature may be filed under.
    ///
    /// - Personal is offered ONLY when an existing user-scoped signature reveals
    ///   the principal's own user id: upstream requires `scope.id == actor.id`
    ///   (`requireManageScope`) and no route tells a client its user id. Without
    ///   one, a "Personal" option could only ever 403.
    /// - Mailboxes need `manager` access upstream. An unreported access level
    ///   (`nil`) is offered rather than hidden — the server is the authority and
    ///   hiding a scope the user does have is the worse failure.
    /// - Domains come from the mailbox addresses' `mailDomainID`; upstream
    ///   additionally requires an owner/admin role, which the client cannot see.
    static func scopeOptions(
        mailboxes: [Mailbox],
        existing: [Signature]
    ) -> [SignatureScopeOption] {
        var options: [SignatureScopeOption] = []

        if let userScopeID = existing.first(where: { $0.scope == .user })?.scopeID {
            options.append(
                SignatureScopeOption(
                    ref: SignatureScopeRef(type: .user, id: userScopeID),
                    label: "Personal"
                )
            )
        }

        for mailbox in mailboxes where mailbox.accessLevel == .manager || mailbox.accessLevel == nil {
            options.append(
                SignatureScopeOption(
                    ref: SignatureScopeRef(type: .mailbox, id: mailbox.id),
                    label: mailbox.displayName.isEmpty ? mailbox.address : mailbox.displayName
                )
            )
        }

        // One option per distinct domain id. Two mailboxes on the same domain
        // must not produce two identical rows.
        var seenDomains: Set<String> = []
        for address in mailboxes.flatMap(\.addresses)
        where !address.mailDomainID.isEmpty && seenDomains.insert(address.mailDomainID).inserted {
            options.append(
                SignatureScopeOption(
                    ref: SignatureScopeRef(type: .domain, id: address.mailDomainID),
                    label: Self.domainName(of: address.address) ?? address.mailDomainID
                )
            )
        }
        return options
    }

    /// The part after the `@`, for labelling a domain scope. `nil` when the
    /// address has no usable domain part, which falls back to the raw id.
    static func domainName(of address: String) -> String? {
        guard let at = address.lastIndex(of: "@") else { return nil }
        let domain = String(address[address.index(after: at)...])
        return domain.isEmpty ? nil : domain
    }

    // MARK: - Editing

    func beginCreate() {
        actionError = nil
        editor = SignatureEditor(existing: nil, scope: scopeOptions.first?.ref)
    }

    func beginEdit(_ signature: Signature) {
        actionError = nil
        // The scope is NOT editable: `PATCH /signatures/{id}` has no scope field,
        // so a signature cannot be moved between scopes. Offering the picker
        // would promise a move the API cannot make.
        editor = SignatureEditor(existing: signature, scope: nil)
    }

    /// Saves the open sheet. Leaves it up (with a field-level message) on
    /// failure, so nothing the user typed is lost.
    func save() async {
        guard let editor, !editor.isSaving else { return }
        editor.fieldError = nil
        editor.isSaving = true
        defer { editor.isSaving = false }
        do {
            if let existing = editor.existing {
                _ = try await service.update(id: existing.id, with: editor.update(from: existing))
            } else {
                guard let scope = editor.scope else {
                    editor.fieldError = "Choose where this signature belongs."
                    return
                }
                _ = try await service.create(
                    CreateSignatureInput(
                        name: editor.trimmedName,
                        html: editor.html,
                        scope: scope,
                        isDefault: editor.isDefault
                    )
                )
            }
        } catch {
            editor.fieldError = error.localizedDescription
            return
        }
        self.editor = nil
        await finishMutation()
    }

    func cancelEdit() {
        editor = nil
    }

    // MARK: - Deleting

    func confirmDeletion() async {
        guard let signature = pendingDeletion else { return }
        pendingDeletion = nil
        actionError = nil
        do {
            try await service.delete(id: signature.id)
        } catch {
            // The row stays: nothing was removed server-side, so removing it
            // here would show a deletion that did not happen.
            actionError = error.localizedDescription
            logger.error("Signature delete failed: \(String(describing: error), privacy: .public)")
            return
        }
        await finishMutation()
    }

    func cancelDeletion() {
        pendingDeletion = nil
    }

    /// Re-lists from the server and tells open composers to refetch.
    ///
    /// Re-listing rather than patching the local array: the server demotes the
    /// previous default of a scope when a new one is set, which no local edit
    /// could reproduce without duplicating that rule.
    private func finishMutation() async {
        await load()
        didMutate()
    }
}

/// The create/edit sheet's fields.
@MainActor
@Observable
final class SignatureEditor: Identifiable {
    nonisolated let id = UUID()
    /// `nil` for a new signature; otherwise the row being edited.
    let existing: Signature?
    var name: String
    var html: String
    /// Only set (and only shown) when creating — see ``SignatureSettingsModel/beginEdit(_:)``.
    var scope: SignatureScopeRef?
    var isDefault: Bool
    var fieldError: String?
    var isSaving = false

    init(existing: Signature?, scope: SignatureScopeRef?) {
        self.existing = existing
        self.name = existing?.name ?? ""
        self.html = existing?.html ?? ""
        self.scope = existing.map { SignatureScopeRef(type: $0.scope, id: $0.scopeID) } ?? scope
        self.isDefault = existing?.isDefault ?? false
    }

    var isEditingExisting: Bool { existing != nil }
    var title: String { isEditingExisting ? "Edit Signature" : "New Signature" }
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Save is offered only once there is a name; the length and size rules are
    /// the service's, so they are reported as field errors rather than by
    /// disabling the button with no explanation.
    var canSave: Bool { !trimmedName.isEmpty && !isSaving }

    /// The PATCH body carrying ONLY what actually changed.
    ///
    /// An untouched sheet yields an empty body, which the service then declines
    /// to send at all (`UpdateSignatureInput.isEmpty`) — the server answers 400
    /// `SIGNATURE_INVALID` to a body that says nothing.
    func update(from existing: Signature) -> UpdateSignatureInput {
        UpdateSignatureInput(
            name: trimmedName == existing.name ? nil : trimmedName,
            html: html == existing.html ? nil : html,
            // Only ever sent as a promotion: `false` here would be indistinguishable
            // from "left alone" to a user who never touched the toggle, and would
            // demote a default they did not mean to clear.
            isDefault: isDefault == existing.isDefault ? nil : isDefault
        )
    }
}
