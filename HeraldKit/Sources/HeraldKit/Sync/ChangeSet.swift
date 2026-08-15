import Foundation

/// What a store mutation actually changed, in ids.
///
/// Upserts are change-detecting: a second upsert of identical data returns an
/// empty ``ChangeSet``. Callers (``SyncEngine``) use `isEmpty` to decide whether
/// the UI needs to be told anything at all — an unchanged poll must not
/// invalidate views.
public nonisolated struct ChangeSet: Sendable, Hashable {
    public var inserted: Set<String>
    public var updated: Set<String>
    public var deleted: Set<String>

    public init(inserted: Set<String> = [], updated: Set<String> = [], deleted: Set<String> = []) {
        self.inserted = inserted
        self.updated = updated
        self.deleted = deleted
    }

    public var isEmpty: Bool { inserted.isEmpty && updated.isEmpty && deleted.isEmpty }

    /// Every id touched, whatever the kind of change.
    public var touched: Set<String> { inserted.union(updated).union(deleted) }

    public mutating func formUnion(_ other: ChangeSet) {
        inserted.formUnion(other.inserted)
        updated.formUnion(other.updated)
        deleted.formUnion(other.deleted)
    }

    public func union(_ other: ChangeSet) -> ChangeSet {
        var copy = self
        copy.formUnion(other)
        return copy
    }
}
