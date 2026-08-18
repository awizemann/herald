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
    /// True when this set came from an account's FIRST full listing (journal
    /// bootstrap, or a legacy pass against an empty cache).
    ///
    /// A bootstrap reports every existing row as `inserted`, so without this flag
    /// signing in would fire a notification for every unread message the server
    /// has ever held. Consumers that treat `inserted` as "new mail arrived"
    /// (``NewMailNotifier``) must stay silent for a bootstrap set.
    public var isBootstrap: Bool

    public init(
        inserted: Set<String> = [],
        updated: Set<String> = [],
        deleted: Set<String> = [],
        isBootstrap: Bool = false
    ) {
        self.inserted = inserted
        self.updated = updated
        self.deleted = deleted
        self.isBootstrap = isBootstrap
    }

    public var isEmpty: Bool { inserted.isEmpty && updated.isEmpty && deleted.isEmpty }

    /// Every id touched, whatever the kind of change.
    public var touched: Set<String> { inserted.union(updated).union(deleted) }

    public mutating func formUnion(_ other: ChangeSet) {
        inserted.formUnion(other.inserted)
        updated.formUnion(other.updated)
        deleted.formUnion(other.deleted)
        // A pass that bootstrapped ANY part of itself is a bootstrap pass: the
        // union carries rows that were merely "not in the cache yet".
        isBootstrap = isBootstrap || other.isBootstrap
    }

    public func union(_ other: ChangeSet) -> ChangeSet {
        var copy = self
        copy.formUnion(other)
        return copy
    }
}
