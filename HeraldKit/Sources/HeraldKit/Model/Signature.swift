import Foundation

/// Who a signature belongs to. The server resolves the AUTOMATIC pick in this
/// precedence: mailbox default, then user default, then domain default
/// (`worker/features/signatures/service.ts`, `automaticSignature`).
public nonisolated enum SignatureScope: String, Sendable, Hashable, Codable {
    case user
    case mailbox
    case domain
}

/// One signature the current principal may use from a given From address.
///
/// `GET /signatures?from=…` returns only the signatures usable from that EXACT
/// address — personal, that mailbox's, and that mailbox's domain's.
public nonisolated struct Signature: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String
    /// Sanitised markup. Herald never sends this anywhere: the server appends the
    /// signature itself. Kept because a future rich composer will preview it.
    public let html: String
    /// Plain-text rendering — what Herald shows in the compose preview.
    public let text: String
    public let scope: SignatureScope
    public let scopeID: String
    /// Human label for the scope (mailbox address/name, or domain name).
    public let scopeLabel: String
    /// Whether this is the default WITHIN its scope. The overall automatic pick is
    /// ``SignatureCandidates/automaticSignatureID``, not this flag.
    public let isDefault: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        name: String,
        html: String,
        text: String,
        scope: SignatureScope,
        scopeID: String,
        scopeLabel: String,
        isDefault: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.html = html
        self.text = text
        self.scope = scope
        self.scopeID = scopeID
        self.scopeLabel = scopeLabel
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Answer of `GET /signatures?from=…`.
public nonisolated struct SignatureCandidates: Sendable, Hashable, Codable {
    /// The signature `{"mode":"automatic"}` resolves to, or `nil` when this
    /// address has no default at any scope.
    public let automaticSignatureID: String?
    public let signatures: [Signature]

    public init(automaticSignatureID: String?, signatures: [Signature]) {
        self.automaticSignatureID = automaticSignatureID
        self.signatures = signatures
    }

    public static let empty = SignatureCandidates(automaticSignatureID: nil, signatures: [])

    /// The signature the given selection resolves to against THIS candidate list.
    /// `nil` for `.none`, for an automatic pick that does not exist, and for a
    /// selected id the address can no longer use (deleted, or scope revoked).
    public func resolved(_ selection: SignatureSelection) -> Signature? {
        switch selection {
        case .noSignature: return nil
        case .automatic:
            guard let automaticSignatureID else { return nil }
            return signatures.first { $0.id == automaticSignatureID }
        case .selected(let id):
            return signatures.first { $0.id == id }
        }
    }
}

/// What the client ASKS FOR: sent as the `signature` field of a draft, send,
/// reply or forward body.
///
/// The server resolves the selection into a ``SignatureSnapshot`` and appends the
/// signature to the outgoing message itself (`worker/features/send/body.ts`
/// assembles authored text, then signature, then quoted context). Herald must
/// therefore NEVER concatenate a signature into the body — same invariant as the
/// quoted original.
public nonisolated enum SignatureSelection: Sendable, Hashable, Codable {
    /// Let the server pick the default for the sending address.
    case automatic
    /// A specific signature. The server answers 400 `SIGNATURE_NOT_AVAILABLE`
    /// when the id is not usable from the From address.
    case selected(id: String)
    /// Send nothing.
    ///
    /// Spelled `noSignature`, not `none`: `signature: .none` on the optional
    /// `signature` field of a send body would bind to `Optional.none` and OMIT
    /// the field, which the server reads as "no selection" — a different thing
    /// on a draft-backed send, and a silent way to lose the user's choice.
    case noSignature

    /// The selection that reproduces a stored snapshot.
    ///
    /// A snapshot whose mode is `selected` but whose id is gone (the signature was
    /// deleted after the draft was saved) falls back to `automatic` — which is
    /// exactly what the server does on the next save of that draft
    /// (`resolveDraftSignature`).
    public init(_ snapshot: SignatureSnapshot) {
        switch snapshot.mode {
        case .none: self = .noSignature
        case .automatic: self = .automatic
        case .selected: self = snapshot.id.map { .selected(id: $0) } ?? .automatic
        }
    }
}

/// What the server STORED: the resolved signature, copied onto the draft (and
/// used verbatim when that draft is sent).
///
/// Display-only on the client. `html`/`text` are the server's own rendering; a
/// preview may show `text`, but nothing may fold it into the body.
public nonisolated struct SignatureSnapshot: Sendable, Hashable, Codable {
    public enum Mode: String, Sendable, Hashable, Codable {
        case automatic
        case selected
        case none
    }

    public let mode: Mode
    /// `nil` when the selection resolved to no signature at all.
    public let id: String?
    public let name: String
    public let html: String
    public let text: String

    public init(mode: Mode, id: String?, name: String, html: String, text: String) {
        self.mode = mode
        self.id = id
        self.name = name
        self.html = html
        self.text = text
    }

    /// The "no signature" snapshot, matching the server's `emptySignatureSnapshot`.
    /// Named `empty` rather than `none` so it can never be confused with
    /// `Optional.none` at a call site.
    public static let empty = SignatureSnapshot(mode: .none, id: nil, name: "", html: "", text: "")

    /// Whether this snapshot would put anything in the message. The server drops a
    /// signature whose text is blank (`assembleMessageBody`).
    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
