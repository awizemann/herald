import Foundation
import HeraldKit

/// One committed recipient in a To/Cc/Bcc token field.
///
/// Derived — never stored: the field's STRING (``ComposeViewModel/toText`` …)
/// stays the source of truth, so draft save, dirty tracking and send
/// idempotency see exactly what they always saw. Tokens are that string
/// parsed; every token edit rewrites the string.
nonisolated struct RecipientToken: Identifiable, Hashable, Sendable {
    /// Position plus address: stable while the list is unchanged, and two
    /// equal addresses can never collide (the parse dedupes them anyway).
    var id: String { "\(index):\(address.lowercased())" }
    let index: Int
    let address: String
    /// A name Herald already knows for this address (the account's own
    /// addresses), else `nil` — the token then shows the address.
    let displayName: String?
    /// ``EmailAddress/isValid(_:)`` — the same rule the send path checks.
    let isValid: Bool

    /// What the token draws.
    var label: String { displayName ?? address }
}

/// The pure token operations, over the field's string. Static so each one is
/// assertable as a string → string round trip.
nonisolated enum RecipientTokens {
    /// Characters that end a pending entry and commit it.
    static let separators: Set<Character> = [",", ";", "\n"]

    static func tokens(in text: String, names: [String: String]) -> [RecipientToken] {
        ComposeViewModel.parseAddresses(text).enumerated().map { index, address in
            RecipientToken(
                index: index,
                address: address,
                displayName: names[address.lowercased()].flatMap { $0.isEmpty ? nil : $0 },
                isValid: EmailAddress.isValid(address)
            )
        }
    }

    /// The field string for `addresses`: the one spelling every token edit
    /// writes back.
    static func text(_ addresses: [String]) -> String {
        EmailAddress.dedupe(addresses).joined(separator: ", ")
    }

    /// `text` with `pending` committed onto the end (split like a paste).
    static func committing(_ pending: String, onto text: String) -> String {
        let added = ComposeViewModel.parseAddresses(pending)
        guard !added.isEmpty else { return text }
        return Self.text(ComposeViewModel.parseAddresses(text) + added)
    }

    /// `text` without the token at `index`; unchanged when out of range.
    static func removing(at index: Int, from text: String) -> String {
        var addresses = ComposeViewModel.parseAddresses(text)
        guard addresses.indices.contains(index) else { return text }
        addresses.remove(at: index)
        return Self.text(addresses)
    }

    /// Splits typed text at its last separator: everything before commits,
    /// the fragment after stays pending. `("a@b.co, c", …)` → commit `a@b.co`,
    /// pending `" c"` trimmed to `"c"`.
    static func splitTyped(_ typed: String) -> (commit: String, pending: String) {
        guard let last = typed.lastIndex(where: { separators.contains($0) }) else { return ("", typed) }
        let commit = String(typed[..<last])
        let pending = String(typed[typed.index(after: last)...]).trimmingCharacters(in: .whitespaces)
        return (commit, pending)
    }

    /// What Delete on an empty token input does.
    enum DeleteAction: Equatable {
        /// Not ours: there is pending text, or no token.
        case ignore
        /// Select this token (the first Delete).
        case select(Int)
        /// Remove this token (Delete with a token selected — the last one, or
        /// whichever the user clicked).
        case remove(Int)
    }

    static func deleteAction(pendingIsEmpty: Bool, tokenCount: Int, selected: Int?) -> DeleteAction {
        guard pendingIsEmpty, tokenCount > 0 else { return .ignore }
        if let selected, (0..<tokenCount).contains(selected) { return .remove(selected) }
        return .select(tokenCount - 1)
    }
}
