import Foundation
import OSLog
import SwiftData

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "MailStoreLabels")

/// Everything one optimistic label change wrote, so it can be undone exactly.
///
/// Assignments are rows, not fields, so the undo is a list of rows to put back
/// (a remove) or to take away again (an add) rather than a snapshot of values.
public nonisolated struct LabelActionUndo: Sendable, Hashable {
    public let accountID: String
    public let labelID: String
    /// Whether the action ADDED the label. The revert does the opposite.
    public let assigned: Bool
    /// (messageID, threadID) pairs the action actually created or removed. A
    /// message that already had the label contributes nothing: reverting it would
    /// take away a label the action never granted.
    public let messages: [LabelRowKey]

    public init(accountID: String, labelID: String, assigned: Bool, messages: [LabelRowKey]) {
        self.accountID = accountID
        self.labelID = labelID
        self.assigned = assigned
        self.messages = messages
    }

    public var isEmpty: Bool { messages.isEmpty }
}

/// One assignment row's identity.
public nonisolated struct LabelRowKey: Sendable, Hashable {
    public let messageID: String
    public let threadID: String

    public init(messageID: String, threadID: String) {
        self.messageID = messageID
        self.threadID = threadID
    }
}

extension MailStore {
    // MARK: - Labels

    /// Every cached label for an account, ordered case-insensitively by name —
    /// the server's own `ORDER BY name COLLATE NOCASE` order, so the sidebar
    /// matches the web app.
    public func labels(accountID: String) throws -> [MailLabel] {
        let descriptor = FetchDescriptor<CachedLabel>(
            predicate: #Predicate { $0.accountID == accountID },
            sortBy: [SortDescriptor(\.sortName, order: .forward), SortDescriptor(\.id, order: .forward)]
        )
        do {
            return try modelContext.fetch(descriptor).map(Self.label(from:))
        } catch {
            logger.error("Label fetch failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Replaces the account's label list with `labels`, and reports whether
    /// anything actually changed — an unchanged poll must not invalidate the UI.
    ///
    /// A label the server no longer lists is deleted along with its assignments:
    /// the workspace deleted it, and upstream cascades the join table.
    @discardableResult
    public func replaceLabels(_ labels: [MailLabel], accountID: String) throws -> Bool {
        do {
            var changed = false
            let existing = try modelContext.fetch(
                FetchDescriptor<CachedLabel>(predicate: #Predicate { $0.accountID == accountID })
            )
            var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for label in labels {
                let row = byID.removeValue(forKey: label.id) ?? {
                    let fresh = CachedLabel(id: label.id, accountID: accountID)
                    modelContext.insert(fresh)
                    changed = true
                    return fresh
                }()
                if row.name != label.name { row.name = label.name; changed = true }
                let sortName = label.name.lowercased()
                if row.sortName != sortName { row.sortName = sortName; changed = true }
                if row.colorRaw != label.color.rawValue { row.colorRaw = label.color.rawValue; changed = true }
                if row.createdAt != label.createdAt { row.createdAt = label.createdAt; changed = true }
                if row.updatedAt != label.updatedAt { row.updatedAt = label.updatedAt; changed = true }
            }
            for (id, row) in byID {
                modelContext.delete(row)
                try modelContext.delete(
                    model: CachedLabelAssignment.self,
                    where: #Predicate { $0.accountID == accountID && $0.labelID == id }
                )
                changed = true
            }
            if changed { try save() }
            return changed
        } catch {
            logger.error("Label replace failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    // MARK: - Assignments

    /// Writes the membership EMBEDDED in message rows.
    ///
    /// Upstream 1.4.2 answers `includeLabels=true` with the message's own labels
    /// on every `MessageSummary` it returns — listings, the thread route, the
    /// single-message route, action results and, crucially, the `/changes`
    /// journal. That makes ROWS the primary membership source: a label assigned
    /// anywhere in the workspace bumps `messages.updated_at`, so the journal
    /// already carries the message, and now it carries what its labels became.
    ///
    /// THE `nil` / `[]` DISTINCTION IS THE WHOLE CONTRACT. A summary whose
    /// `labels` is `nil` is skipped entirely: the key was absent, either because
    /// the client did not ask or — the case that matters — because the server
    /// predates 1.4.2, and for those servers the per-label sweep is still the
    /// only truth there is. Treating `nil` as "no labels" would wipe every chip
    /// in the cache on the first pass against a 1.3.4 server. `[]` DOES clear the
    /// message's labels, because that is the server saying so.
    ///
    /// Per-MESSAGE authoritative, never per-label: this replaces the label set of
    /// the messages it is given and touches no other row, so it can never erase a
    /// label's membership the way a truncated sweep could. The sweep remains for
    /// the one thing rows cannot report — a label DELETED workspace-wide never
    /// touches a message, so no row ever mentions it again (see
    /// ``replaceAssignments(labelID:messages:accountID:)`` and
    /// `SyncEngine.syncLabelsIfDue`).
    @discardableResult
    public func applyEmbeddedLabels(from summaries: [MessageSummary], accountID: String) throws -> Bool {
        let stated = summaries.compactMap { summary in
            summary.labels.map {
                MessageLabelWrite(
                    messageID: summary.id, threadID: summary.threadID, labelIDs: $0.map(\.id)
                )
            }
        }
        guard !stated.isEmpty else { return false }
        do {
            let changed = try writeMessageAssignments(stated, accountID: accountID)
            if changed { try save() }
            return changed
        } catch {
            logger.error("Embedded label write failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// One message's full label set, as ``writeMessageAssignments`` takes it.
    private struct MessageLabelWrite {
        let messageID: String
        let threadID: String
        let labelIDs: [String]
    }

    /// Replaces the WHOLE membership of one label with `messages`.
    ///
    /// This is what the per-label RECONCILIATION sweep writes:
    /// `GET /messages?labelId=…` is a complete listing of that label, so anything
    /// missing from it no longer carries the label. Only call it with a listing
    /// that reached its end — a truncated page-walk would erase assignments the
    /// server never got to return, exactly like the message tombstoning rule.
    ///
    /// Since 1.4.2 this is no longer the primary path — embedded row labels are
    /// (``applyEmbeddedLabels(from:accountID:)``). It stays because it is the
    /// only write that can REMOVE a label from messages no row will ever mention
    /// again, and because a pre-1.4.2 server has nothing else.
    ///
    /// ACCEPTED: the rows written here are NOT constrained to messages the cache
    /// holds. The label listing is the only membership source v1 offers and it
    /// covers the whole account, while the message cache only covers the synced
    /// folders (and only as far back as the page-walks reached) — so a label
    /// legitimately names messages this store has never seen, and the sweep
    /// inserts assignments for them. That is deliberate: dropping them would make
    /// the label's own listing lie by omission the moment the missing message is
    /// synced, and there is no cheap way to distinguish "not cached yet" from
    /// "not real". The cost is that a label's assignment count can exceed what
    /// the by-label conversation listing can show — that listing joins against
    /// cached conversations and simply skips the unknown ids — so the two
    /// disagree until the messages arrive. Any badge built from these rows must
    /// therefore count what the listing can RESOLVE, never `CachedLabelAssignment`
    /// rows. Assignments for ids that turn out never to exist are collected when
    /// their label is deleted (``replaceLabels(_:accountID:)``) or the account is.
    @discardableResult
    public func replaceAssignments(
        labelID: String,
        messages: [LabelRowKey],
        accountID: String
    ) throws -> Bool {
        do {
            var changed = false
            let existing = try modelContext.fetch(
                FetchDescriptor<CachedLabelAssignment>(
                    predicate: #Predicate { $0.accountID == accountID && $0.labelID == labelID }
                )
            )
            var byMessage = Dictionary(existing.map { ($0.messageID, $0) }, uniquingKeysWith: { first, _ in first })
            for message in messages {
                guard let row = byMessage.removeValue(forKey: message.messageID) else {
                    modelContext.insert(CachedLabelAssignment(
                        accountID: accountID,
                        labelID: labelID,
                        messageID: message.messageID,
                        threadID: message.threadID
                    ))
                    changed = true
                    continue
                }
                // A message can be re-threaded server-side; the denormalized copy
                // has to follow or the conversation chips point at a dead thread.
                if row.threadID != message.threadID {
                    row.threadID = message.threadID
                    changed = true
                }
            }
            for row in byMessage.values {
                modelContext.delete(row)
                changed = true
            }
            if changed { try save() }
            return changed
        } catch {
            logger.error("Label assignment replace failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Everything the sidebar and the row chips read off one fetch of the
    /// assignment table.
    public nonisolated struct LabelIndex: Sendable {
        /// thread id → the label ids on any of its messages.
        public let idsByThread: [String: Set<String>]
        /// label id → how many CACHED conversations carry it. See
        /// ``MailStore/labelIndex(accountID:)`` for why it is not a row count.
        public let threadCounts: [String: Int]

        public static let empty = LabelIndex(idsByThread: [:], threadCounts: [:])

        public init(idsByThread: [String: Set<String>], threadCounts: [String: Int]) {
            self.idsByThread = idsByThread
            self.threadCounts = threadCounts
        }
    }

    /// The thread → labels index AND the per-label thread counts, in one pass.
    ///
    /// One fetch for the whole account rather than one per row: the conversation
    /// list draws chips on every visible row, and a per-row query would be a
    /// round trip per row per reload.
    ///
    /// The counts are computed HERE rather than by the view walking the index,
    /// because they must agree with what the by-label listing can actually show.
    /// ``replaceAssignments(labelID:messages:accountID:)`` documents why: the
    /// sweep stores assignments for every message the LABEL names, including
    /// messages in folders this cache has never synced, while
    /// ``conversations(withLabel:accountID:limit:)`` can only resolve threads the
    /// conversation cache holds. Counting distinct assignment thread ids would
    /// therefore promise rows the listing then does not show. So the count is
    /// intersected against the cached conversation thread ids — the badge counts
    /// what opening the label will actually list.
    ///
    /// Both walks ask for the columns they read and nothing else
    /// (`propertiesToFetch`) and go through `ModelContext.enumerate`, which pages
    /// the result set instead of materialising the whole table at once. Nothing
    /// here touches a property outside the fetched set, which is the condition
    /// for a partially-materialised model to stay cheap: reading one that was NOT
    /// fetched faults the row in individually and turns the saving into an N+1.
    public func labelIndex(accountID: String) throws -> LabelIndex {
        do {
            var assignments = FetchDescriptor<CachedLabelAssignment>(
                predicate: #Predicate { $0.accountID == accountID }
            )
            assignments.propertiesToFetch = [\.threadID, \.labelID]
            var idsByThread: [String: Set<String>] = [:]
            try modelContext.enumerate(assignments, batchSize: Self.labelFetchBatchSize) { row in
                idsByThread[row.threadID, default: []].insert(row.labelID)
            }
            guard !idsByThread.isEmpty else { return .empty }

            var conversations = FetchDescriptor<CachedConversation>(
                predicate: #Predicate { $0.accountID == accountID }
            )
            conversations.propertiesToFetch = [\.threadID]
            // A thread legitimately has a row per listing scope, so this is a SET
            // of ids and the count below is per distinct thread, matching the
            // listing's own dedup.
            var cachedThreads: Set<String> = []
            try modelContext.enumerate(conversations, batchSize: Self.labelFetchBatchSize) { row in
                cachedThreads.insert(row.threadID)
            }

            var threadCounts: [String: Int] = [:]
            for (threadID, labelIDs) in idsByThread where cachedThreads.contains(threadID) {
                for labelID in labelIDs { threadCounts[labelID, default: 0] += 1 }
            }
            return LabelIndex(idsByThread: idsByThread, threadCounts: threadCounts)
        } catch {
            logger.error("Label index fetch failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// label id → the thread ids carrying it, for every label of the account.
    public func labelIDsByThread(accountID: String) throws -> [String: [String]] {
        try labelIndex(accountID: accountID).idsByThread.mapValues { Array($0) }
    }

    /// How many rows a batched walk materialises at a time.
    ///
    /// `ModelContext.enumerate` defaults to 5,000, which for the assignment table
    /// is every label of every message the account has ever synced held live at
    /// once. 500 keeps the peak bounded without making the walk a round trip per
    /// handful.
    static let labelFetchBatchSize = 500

    /// How many thread ids go into one `contains` predicate. SQLite's default
    /// variable ceiling is 999 bound parameters and the predicate spends one per
    /// id plus a couple for the account, so 500 stays clear of it with room.
    static let labelPredicateChunkSize = 500

    /// The label ids on one MESSAGE (not its thread) — what the reading pane draws.
    public func labelIDs(messageID: String, accountID: String) throws -> [String] {
        do {
            return try modelContext.fetch(
                FetchDescriptor<CachedLabelAssignment>(
                    predicate: #Predicate { $0.accountID == accountID && $0.messageID == messageID }
                )
            ).map(\.labelID)
        } catch {
            logger.error("Message label fetch failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Conversation rows carrying one label, newest first and DEDUPED by thread.
    ///
    /// A thread legitimately has a row per listing scope (inbox and archived, say)
    /// and a label listing is not one of those scopes, so the newest row per
    /// thread is the one shown — the same row the folder list would have shown.
    public func conversations(
        withLabel labelID: String,
        accountID: String,
        limit: Int = 200
    ) throws -> [ConversationSummary] {
        do {
            var assignments = FetchDescriptor<CachedLabelAssignment>(
                predicate: #Predicate { $0.accountID == accountID && $0.labelID == labelID }
            )
            assignments.propertiesToFetch = [\.threadID]
            var unique: Set<String> = []
            try modelContext.enumerate(assignments, batchSize: Self.labelFetchBatchSize) { row in
                unique.insert(row.threadID)
            }
            let threadIDs = Array(unique)
            guard !threadIDs.isEmpty else { return [] }

            // The thread-id filter now runs in the STORE. It used to materialise
            // every cached conversation of the account and filter in Swift, which
            // is O(all conversations) per label open and per label toggle while a
            // listing is up — the audit's P1. A captured `Array.contains` DOES
            // compile inside `#Predicate` (it is `Sequence.contains`, unlike the
            // `Set.contains` the earlier note tried); the ids are chunked only to
            // stay under SQLite's bound-parameter ceiling, and each chunk is
            // sorted and limited by the store rather than in memory.
            var seen: Set<String> = []
            // `sortDate` is a column, not part of `ConversationSummary`, so the
            // cross-chunk merge below has to carry it alongside.
            var rows: [(sortDate: Date, summary: ConversationSummary)] = []
            for chunk in stride(from: 0, to: threadIDs.count, by: Self.labelPredicateChunkSize) {
                let ids = Array(
                    threadIDs[chunk ..< min(chunk + Self.labelPredicateChunkSize, threadIDs.count)]
                )
                var descriptor = FetchDescriptor<CachedConversation>(
                    predicate: #Predicate {
                        $0.accountID == accountID && ids.contains($0.threadID)
                    },
                    sortBy: [SortDescriptor(\.sortDate, order: .reverse)]
                )
                // NOT `fetchLimit`: a thread holds one row per listing scope and
                // the dedup below drops the older ones, so `limit` presented rows
                // can need more than `limit` fetched ones. The walk stops on
                // DISTINCT threads instead.
                descriptor.fetchLimit = nil
                var kept = 0
                for row in try modelContext.fetch(descriptor) {
                    guard seen.insert(row.threadID).inserted else { continue }
                    rows.append((row.sortDate, Self.conversation(from: row)))
                    kept += 1
                    // Each chunk comes back newest-first from the STORE, so the
                    // globally newest `limit` threads are a subset of the union
                    // of each chunk's newest `limit` — taking more per chunk
                    // cannot change the answer, only the work.
                    if kept >= limit { break }
                }
            }
            // One chunk is newest-first on its own; several are not, so the merge
            // is re-sorted before the cap. `sortDate` is what the folder listing
            // orders by, and the newest row per thread is the one kept above.
            if threadIDs.count > Self.labelPredicateChunkSize {
                rows.sort { $0.sortDate > $1.sortDate }
            }
            return rows.prefix(limit).map(\.summary)
        } catch {
            logger.error("Label conversation fetch failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    // MARK: - Optimistic writes

    /// Applies a label change to every cached message of one thread, and returns
    /// the undo for the rows it actually changed.
    public func applyLocalLabel(
        _ labelID: String,
        threadID: String,
        accountID: String,
        assigned: Bool
    ) throws -> LabelActionUndo {
        do {
            let messages = try modelContext.fetch(
                FetchDescriptor<CachedMessage>(
                    predicate: #Predicate { $0.accountID == accountID && $0.threadID == threadID }
                )
            )
            let keys = messages.map { LabelRowKey(messageID: $0.id, threadID: $0.threadID) }
            let touched = try setAssignments(labelID: labelID, rows: keys, accountID: accountID, assigned: assigned)
            if !touched.isEmpty { try save() }
            return LabelActionUndo(
                accountID: accountID, labelID: labelID, assigned: assigned, messages: touched
            )
        } catch {
            logger.error("Local label change failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Same for a single message.
    public func applyLocalLabel(
        _ labelID: String,
        messageID: String,
        accountID: String,
        assigned: Bool
    ) throws -> LabelActionUndo {
        do {
            guard let message = try fetchMessage(id: messageID, accountID: accountID) else {
                return LabelActionUndo(accountID: accountID, labelID: labelID, assigned: assigned, messages: [])
            }
            let key = LabelRowKey(messageID: message.id, threadID: message.threadID)
            let touched = try setAssignments(labelID: labelID, rows: [key], accountID: accountID, assigned: assigned)
            if !touched.isEmpty { try save() }
            return LabelActionUndo(
                accountID: accountID, labelID: labelID, assigned: assigned, messages: touched
            )
        } catch {
            logger.error("Local label change failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Puts back exactly what ``applyLocalLabel`` changed.
    public func revertLocalLabel(_ undo: LabelActionUndo) throws {
        guard !undo.isEmpty else { return }
        do {
            let touched = try setAssignments(
                labelID: undo.labelID,
                rows: undo.messages,
                accountID: undo.accountID,
                assigned: !undo.assigned
            )
            if !touched.isEmpty { try save() }
        } catch {
            logger.error("Label revert failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Writes the server's authoritative answer for ONE message.
    ///
    /// `LabelAssignmentResult.labels` is the message's full set after the write,
    /// so this replaces rather than merges — an assignment made elsewhere since
    /// the last reconciliation is picked up for free.
    ///
    /// The thread id comes from the CACHED row here, because a
    /// `LabelAssignmentResult` does not carry the message's summary; a message
    /// the cache does not hold is a no-op, as it always was.
    @discardableResult
    public func setMessageLabels(
        _ labelIDs: [String],
        messageID: String,
        accountID: String
    ) throws -> Bool {
        do {
            guard let message = try fetchMessage(id: messageID, accountID: accountID) else { return false }
            let changed = try writeMessageAssignments(
                [MessageLabelWrite(messageID: messageID, threadID: message.threadID, labelIDs: labelIDs)],
                accountID: accountID
            )
            if changed { try save() }
            return changed
        } catch {
            logger.error("Message label write failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Replaces the label set of each given message, in ONE fetch, WITHOUT
    /// saving. The shared core of ``setMessageLabels(_:messageID:accountID:)``
    /// (one message, from the server's assignment answer) and
    /// ``applyEmbeddedLabels(from:accountID:)`` (a whole journal page).
    ///
    /// A page of 100 journal upserts each carrying labels would otherwise be 100
    /// fetches and 100 saves. The existing rows are read by message id in chunks
    /// (SQLite's bound-parameter ceiling, ``labelPredicateChunkSize``) and
    /// matched in memory, the same shape ``setAssignments`` uses for a thread.
    private func writeMessageAssignments(
        _ writes: [MessageLabelWrite],
        accountID: String
    ) throws -> Bool {
        guard !writes.isEmpty else { return false }
        let messageIDs = Array(Set(writes.map(\.messageID)))
        var existing: [String: [CachedLabelAssignment]] = [:]
        for start in stride(from: 0, to: messageIDs.count, by: Self.labelPredicateChunkSize) {
            let ids = Array(messageIDs[start ..< min(start + Self.labelPredicateChunkSize, messageIDs.count)])
            let rows = try modelContext.fetch(
                FetchDescriptor<CachedLabelAssignment>(
                    predicate: #Predicate { $0.accountID == accountID && ids.contains($0.messageID) }
                )
            )
            for row in rows { existing[row.messageID, default: []].append(row) }
        }

        var changed = false
        for write in writes {
            var byLabel = Dictionary(
                (existing[write.messageID] ?? []).map { ($0.labelID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for labelID in write.labelIDs {
                guard let row = byLabel.removeValue(forKey: labelID) else {
                    modelContext.insert(CachedLabelAssignment(
                        accountID: accountID,
                        labelID: labelID,
                        messageID: write.messageID,
                        threadID: write.threadID
                    ))
                    changed = true
                    continue
                }
                // A message can be re-threaded server-side; the denormalized copy
                // has to follow or the conversation chips point at a dead thread.
                if row.threadID != write.threadID {
                    row.threadID = write.threadID
                    changed = true
                }
            }
            for row in byLabel.values {
                modelContext.delete(row)
                changed = true
            }
        }
        return changed
    }

    /// Settles ONE label across every cached message of a thread, after the
    /// server confirmed a conversation-level write.
    ///
    /// Deliberately NOT `setMessageLabels` with the answer's `labels`: for a
    /// conversation the server reports the DISTINCT UNION across the thread, which
    /// is not any single message's set. Writing the union onto the representative
    /// message would hand it labels its siblings carry and strip ones it has
    /// alone. Only the label that was actually toggled is authoritative per
    /// message here — every other label is left exactly as the cache had it, for
    /// the sweep to correct.
    @discardableResult
    public func settleThreadLabel(
        _ labelID: String,
        threadID: String,
        accountID: String,
        assigned: Bool
    ) throws -> Bool {
        do {
            let messages = try modelContext.fetch(
                FetchDescriptor<CachedMessage>(
                    predicate: #Predicate { $0.accountID == accountID && $0.threadID == threadID }
                )
            )
            let rows = messages.map { LabelRowKey(messageID: $0.id, threadID: $0.threadID) }
            let touched = try setAssignments(
                labelID: labelID, rows: rows, accountID: accountID, assigned: assigned
            )
            if !touched.isEmpty { try save() }
            return !touched.isEmpty
        } catch {
            logger.error("Thread label settle failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Adds or removes one label across a set of rows, WITHOUT saving, and
    /// returns only the rows that actually moved — the rows an undo owns.
    private func setAssignments(
        labelID: String,
        rows: [LabelRowKey],
        accountID: String,
        assigned: Bool
    ) throws -> [LabelRowKey] {
        // ONE fetch for the label, then matched in memory: a fetch per row made a
        // forty-message thread forty round trips, and the revert path repeated
        // them. The label's own assignment set is small and index-served.
        let existing = try modelContext.fetch(
            FetchDescriptor<CachedLabelAssignment>(
                predicate: #Predicate { $0.accountID == accountID && $0.labelID == labelID }
            )
        )
        var byMessage: [String: [CachedLabelAssignment]] = [:]
        for row in existing { byMessage[row.messageID, default: []].append(row) }
        // Which messages hold the label RIGHT NOW, updated as we go, so a
        // repeated id in `rows` cannot insert the same assignment twice.
        var holders = Set(byMessage.keys)

        var touched: [LabelRowKey] = []
        for row in rows {
            if assigned {
                guard !holders.contains(row.messageID) else { continue }
                modelContext.insert(CachedLabelAssignment(
                    accountID: accountID, labelID: labelID, messageID: row.messageID, threadID: row.threadID
                ))
                holders.insert(row.messageID)
            } else {
                guard holders.contains(row.messageID) else { continue }
                for stale in byMessage[row.messageID] ?? [] { modelContext.delete(stale) }
                holders.remove(row.messageID)
            }
            touched.append(row)
        }
        return touched
    }

    nonisolated static func label(from row: CachedLabel) -> MailLabel {
        MailLabel(
            id: row.id,
            name: row.name,
            color: LabelColor(serverValue: row.colorRaw),
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }
}
