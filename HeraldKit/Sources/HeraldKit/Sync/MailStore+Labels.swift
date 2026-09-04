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

    /// Replaces the WHOLE membership of one label with `messages`.
    ///
    /// This is what the per-label sweep writes: `GET /messages?labelId=…` is a
    /// complete listing of that label, so anything missing from it no longer
    /// carries the label. Only call it with a listing that reached its end —
    /// a truncated page-walk would erase assignments the server never got to
    /// return, exactly like the message tombstoning rule.
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

    /// label id → the thread ids carrying it, for every label of the account.
    ///
    /// One fetch for the whole account rather than one per row: the conversation
    /// list draws chips on every visible row, and a per-row query would be a
    /// round trip per row per reload.
    public func labelIDsByThread(accountID: String) throws -> [String: [String]] {
        do {
            let rows = try modelContext.fetch(
                FetchDescriptor<CachedLabelAssignment>(
                    predicate: #Predicate { $0.accountID == accountID }
                )
            )
            var result: [String: Set<String>] = [:]
            for row in rows {
                result[row.threadID, default: []].insert(row.labelID)
            }
            return result.mapValues { Array($0) }
        } catch {
            logger.error("Label index fetch failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

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
            let threadIDs = Set(try modelContext.fetch(
                FetchDescriptor<CachedLabelAssignment>(
                    predicate: #Predicate { $0.accountID == accountID && $0.labelID == labelID }
                )
            ).map(\.threadID))
            guard !threadIDs.isEmpty else { return [] }
            // Fetched by account and sorted in the store, then filtered in Swift:
            // `#Predicate` cannot take a `Set.contains` over a captured collection
            // of this shape, and the alternative is one fetch per thread.
            var descriptor = FetchDescriptor<CachedConversation>(
                predicate: #Predicate { $0.accountID == accountID },
                sortBy: [SortDescriptor(\.sortDate, order: .reverse)]
            )
            descriptor.fetchLimit = nil
            var seen: Set<String> = []
            var rows: [ConversationSummary] = []
            for row in try modelContext.fetch(descriptor) {
                guard threadIDs.contains(row.threadID), seen.insert(row.threadID).inserted else { continue }
                rows.append(Self.conversation(from: row))
                if rows.count >= limit { break }
            }
            return rows
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
    /// the last sweep is picked up for free.
    @discardableResult
    public func setMessageLabels(
        _ labelIDs: [String],
        messageID: String,
        accountID: String
    ) throws -> Bool {
        do {
            guard let message = try fetchMessage(id: messageID, accountID: accountID) else { return false }
            let threadID = message.threadID
            var changed = false
            let existing = try modelContext.fetch(
                FetchDescriptor<CachedLabelAssignment>(
                    predicate: #Predicate { $0.accountID == accountID && $0.messageID == messageID }
                )
            )
            var byLabel = Dictionary(existing.map { ($0.labelID, $0) }, uniquingKeysWith: { first, _ in first })
            for labelID in labelIDs where byLabel.removeValue(forKey: labelID) == nil {
                modelContext.insert(CachedLabelAssignment(
                    accountID: accountID, labelID: labelID, messageID: messageID, threadID: threadID
                ))
                changed = true
            }
            for row in byLabel.values {
                modelContext.delete(row)
                changed = true
            }
            if changed { try save() }
            return changed
        } catch {
            logger.error("Message label write failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
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
