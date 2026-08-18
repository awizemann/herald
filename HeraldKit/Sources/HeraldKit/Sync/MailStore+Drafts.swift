import Foundation
import OSLog
import SwiftData

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "MailStore")

/// A draft the user currently has open in a composer, fenced against the poll.
///
/// Keyed per account for the same reason ``PendingKey`` is: the `#Unique` is
/// (accountID, id) and two signed-in servers reuse ids.
nonisolated struct DraftKey: Sendable, Hashable {
    let accountID: String
    let id: String
}

extension MailStore {
    // MARK: - Reads

    /// Every cached draft for the account, newest edit first.
    public func drafts(accountID: String) throws -> [DraftSummary] {
        let descriptor = FetchDescriptor<CachedDraft>(
            predicate: #Predicate { $0.accountID == accountID },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        do {
            return try modelContext.fetch(descriptor).map(Self.draftSummary(from:))
        } catch {
            logger.error("Draft fetch failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// How many drafts the account has — the sidebar badge. `fetchCount`, so no
    /// row (and no body) is materialised to answer it.
    public func draftCount(accountID: String) throws -> Int {
        do {
            return try modelContext.fetchCount(
                FetchDescriptor<CachedDraft>(predicate: #Predicate { $0.accountID == accountID })
            )
        } catch {
            logger.error("Draft count failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// The whole draft, rebuilt from the cache — version stamp included, so the
    /// composer it seeds can `PATCH` without refetching.
    public func draft(id: String, accountID: String) throws -> Draft? {
        do {
            return try fetchDraftRow(id: id, accountID: accountID).map(Self.draft(from:))
        } catch {
            logger.error("Draft fetch failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    // MARK: - Reconcile (the poll's only entry point)

    /// Makes the cache match `listed` exactly: upsert what changed, delete what
    /// the server no longer has.
    ///
    /// A full-list diff rather than a delta because that is the only shape the
    /// server offers — `GET /drafts` has no pagination, no `updatedSince`, and
    /// drafts are absent from the `/changes` journal. It is therefore also
    /// unconditionally complete: unlike the message listing there is no silent
    /// cap to guard against, so tombstoning here is always safe.
    ///
    /// Drafts open in a composer are FENCED (see ``retainOpenDraft(id:accountID:)``):
    /// they are never deleted, and a listing older than what the composer just
    /// saved is never written over the row. A poll that started before the
    /// composer's `POST /drafts` returned would otherwise erase the row the user
    /// is typing into, and the folder would flicker it away and back.
    @discardableResult
    public func reconcileDrafts(_ listed: [Draft], accountID: String) throws -> ChangeSet {
        var changes = ChangeSet()
        do {
            let existing = try fetchAllDraftRows(accountID: accountID)
            var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            for dto in listed {
                guard let row = byID.removeValue(forKey: dto.id) else {
                    let row = CachedDraft(id: dto.id, accountID: accountID)
                    _ = Self.apply(dto, to: row)
                    modelContext.insert(row)
                    changes.inserted.insert(dto.id)
                    continue
                }
                // A fenced row is only overwritten by a listing that is at least
                // as new as the composer's last save. `version` is the server's
                // own monotonic counter, so it is the honest comparison.
                if isDraftOpen(id: dto.id, accountID: accountID), dto.version < row.version {
                    logger.info("Skipping stale listing of open draft \(dto.id, privacy: .public)")
                    continue
                }
                if Self.apply(dto, to: row) { changes.updated.insert(dto.id) }
            }

            // Whatever the server did not return is gone — unless a composer owns
            // it, in which case the server has simply not seen it yet.
            for (id, row) in byID {
                guard !isDraftOpen(id: id, accountID: accountID) else { continue }
                changes.deleted.insert(id)
                modelContext.delete(row)
            }

            if !changes.isEmpty { try save() }
            return changes
        } catch {
            logger.error("Draft reconcile failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    // MARK: - Local writes (the composer's entry points)

    /// Writes what a composer just saved straight into the cache, so the Drafts
    /// folder shows the in-progress draft without waiting for the next poll, and
    /// fences it against that poll for as long as the window is open.
    ///
    /// Older writes are dropped. A composer reports its saves through an
    /// unstructured hop to the main actor, and an autosave racing an attachment
    /// upload can arrive in either order — so the LAST message is not necessarily
    /// the newest state, and without this the folder would show a version of the
    /// draft the server has already moved past.
    @discardableResult
    public func storeLocalDraft(_ draft: Draft, accountID: String) throws -> ChangeSet {
        retainOpenDraft(id: draft.id, accountID: accountID)
        do {
            guard let row = try fetchDraftRow(id: draft.id, accountID: accountID) else {
                let row = CachedDraft(id: draft.id, accountID: accountID)
                _ = Self.apply(draft, to: row)
                modelContext.insert(row)
                try save()
                return ChangeSet(inserted: [draft.id])
            }
            guard draft.version >= row.version else {
                logger.info("Ignoring an out-of-order local save of draft \(draft.id, privacy: .public)")
                return ChangeSet()
            }
            guard Self.apply(draft, to: row) else { return ChangeSet() }
            try save()
            return ChangeSet(updated: [draft.id])
        } catch {
            logger.error("Local draft store failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Drops the row now (the optimistic half of a delete, and what a send or a
    /// discard leaves behind). Also releases the fence: the draft is gone, so
    /// there is nothing left to protect from the poll.
    @discardableResult
    public func deleteDraft(id: String, accountID: String) throws -> ChangeSet {
        releaseOpenDraft(id: id, accountID: accountID)
        do {
            guard let row = try fetchDraftRow(id: id, accountID: accountID) else { return ChangeSet() }
            modelContext.delete(row)
            try save()
            return ChangeSet(deleted: [id])
        } catch {
            logger.error("Draft delete failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    // MARK: - Open-composer fence

    /// Marks a draft as owned by an open composer. (The set itself lives on
    /// ``MailStore`` — an extension cannot hold stored state.)
    public func retainOpenDraft(id: String, accountID: String) {
        openDrafts.insert(DraftKey(accountID: accountID, id: id))
    }

    /// The composer closed: the poll owns the row again.
    public func releaseOpenDraft(id: String, accountID: String) {
        openDrafts.remove(DraftKey(accountID: accountID, id: id))
    }

    /// Whether a composer currently owns this draft.
    ///
    /// Public as a test seam above all: a fence that is never released is a
    /// draft the server can never tombstone from the cache again, and that leak
    /// is invisible from the outside otherwise.
    public func isDraftOpen(id: String, accountID: String) -> Bool {
        openDrafts.contains(DraftKey(accountID: accountID, id: id))
    }

    // MARK: - Row <-> DTO

    /// Writes every field that differs and reports whether anything did — the
    /// same change-detecting shape as every other upsert, so an unchanged poll
    /// emits an empty ``ChangeSet`` and invalidates no view.
    @discardableResult
    nonisolated static func apply(_ dto: Draft, to row: CachedDraft) -> Bool {
        var changed = false
        func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<CachedDraft, T>, _ value: T) {
            guard row[keyPath: keyPath] != value else { return }
            row[keyPath: keyPath] = value
            changed = true
        }
        let content = dto.content
        set(\.version, dto.version)
        set(\.updatedAt, dto.updatedAt)
        set(\.mailboxKey, content.mailboxID ?? "")
        set(\.replyToMessageID, content.replyToMessageID)
        set(\.forwardOfMessageID, content.forwardOfMessageID)
        set(\.fromAddress, content.from)
        set(\.toAddresses, content.to)
        set(\.ccAddresses, content.cc)
        set(\.bccAddresses, content.bcc)
        set(\.subject, content.subject)
        set(\.textBody, content.text)
        set(\.htmlBody, content.html)
        set(\.attachments, dto.attachments)
        return changed
    }

    nonisolated static func draft(from row: CachedDraft) -> Draft {
        Draft(
            id: row.id,
            version: row.version,
            updatedAt: row.updatedAt,
            attachments: row.attachments,
            content: DraftInput(
                mailboxID: row.mailboxKey.isEmpty ? nil : row.mailboxKey,
                replyToMessageID: row.replyToMessageID,
                forwardOfMessageID: row.forwardOfMessageID,
                from: row.fromAddress,
                to: row.toAddresses,
                cc: row.ccAddresses,
                bcc: row.bccAddresses,
                subject: row.subject,
                text: row.textBody,
                html: row.htmlBody,
                // Deliberately NOT stamped: `Draft.editableContent` is what adds
                // the version, and `content` is defined as the unstamped body.
                version: nil
            )
        )
    }

    nonisolated static func draftSummary(from row: CachedDraft) -> DraftSummary {
        DraftSummary(
            id: row.id,
            mailboxID: row.mailboxKey.isEmpty ? nil : row.mailboxKey,
            recipients: row.toAddresses,
            subject: row.subject,
            snippet: DraftSummary.snippet(from: row.textBody),
            updatedAt: row.updatedAt,
            hasAttachments: !row.attachments.isEmpty
        )
    }

    // MARK: - Fetch helpers

    private func fetchDraftRow(id: String, accountID: String) throws -> CachedDraft? {
        var descriptor = FetchDescriptor<CachedDraft>(
            predicate: #Predicate { $0.accountID == accountID && $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchAllDraftRows(accountID: String) throws -> [CachedDraft] {
        try modelContext.fetch(
            FetchDescriptor<CachedDraft>(predicate: #Predicate { $0.accountID == accountID })
        )
    }
}
