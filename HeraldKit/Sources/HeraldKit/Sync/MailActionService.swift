import Foundation
import OSLog

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "MailActions")

/// Optimistic message/conversation actions: mutate the cache first so triage
/// feels instant, POST in the background, revert exactly on failure.
public nonisolated struct MailActionService: Sendable {
    private let api: any MailAPIClient
    private let store: MailStore

    public init(api: any MailAPIClient, store: MailStore) {
        self.api = api
        self.store = store
    }

    /// Applies `action` to one message. Throws the API error after reverting, so
    /// the caller can surface it — the cache is already back to its old state.
    public func perform(_ action: MessageAction, on messageID: String, accountID: String) async throws {
        let undo = try await store.applyLocalAction(action, messageID: messageID, accountID: accountID)
        let confirmed: MessageSummary
        do {
            confirmed = try await api.perform(action, onMessage: messageID)
        } catch {
            logger.warning(
                "Message action \(action.rawValue, privacy: .public) rejected (\(Self.code(for: error), privacy: .public)); reverting: \(error.localizedDescription, privacy: .private)"
            )
            // Best-effort revert: never rethrown (the original API error is what the
            // caller needs), but a revert failure is logged rather than swallowed.
            do {
                try await revert(undo)
            } catch let revertError {
                logger.warning("Revert after a rejected message action failed (\(Self.code(for: revertError), privacy: .public))")
            }
            throw error
        }
        // The server answers with the updated summary. Discarding it left the
        // optimistic guess (a client-side `Date()`) in the cache until some later
        // journal page happened to correct it; it is authoritative, so it is
        // written straight in as the fence comes down. A store failure here must
        // NOT be mistaken for a rejected action — the server already accepted it.
        do {
            try await store.completeLocalAction(undo, applying: [confirmed])
        } catch {
            logger.error("Confirmed action could not be recorded: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Same contract for a whole thread. `folder` is required by the server on
    /// conversation actions (a missing folder is a 400).
    public func perform(
        _ action: ConversationAction,
        onConversation threadID: String,
        in folder: ConversationFolder,
        accountID: String,
        representativeMessageID: String? = nil
    ) async throws {
        // REAL-SERVER FACT: `POST /conversations/{id}/{action}` takes a MESSAGE id
        // (the server looks up the message's mailbox for the access check and
        // derives the thread from it). Sending the thread id resolved to no
        // mailbox → 403 "You do not have access to this mailbox" for star/archive.
        // Any message in the thread works; the newest is the natural pick.
        //
        // `representativeMessageID` is the caller's fallback for a thread the
        // CACHE does not hold — a server-search hit sync has not listed yet.
        // Without it every action on such a row failed here with `.notFound`,
        // before the request was ever made. The cache still wins when it has the
        // thread: it knows the newest member, the caller only knows one.
        let cached = try await store.messages(accountID: accountID, threadID: threadID)
            .max(by: { ($0.receivedAt ?? $0.sentAt ?? .distantPast) < ($1.receivedAt ?? $1.sentAt ?? .distantPast) })
            .map(\.id)
        guard let representative = cached ?? representativeMessageID else {
            throw MailAPIError.notFound
        }
        let undo = try await store.applyLocalAction(action, threadID: threadID, accountID: accountID)
        let result: ConversationActionResult
        do {
            result = try await api.perform(action, onConversation: representative, in: folder)
        } catch {
            logger.warning(
                "Conversation action \(action.rawValue, privacy: .public) rejected (\(Self.code(for: error), privacy: .public)); reverting: \(error.localizedDescription, privacy: .private)"
            )
            // Best-effort revert: never rethrown (the original API error is what the
            // caller needs), but a revert failure is logged rather than swallowed.
            do {
                try await revert(undo)
            } catch let revertError {
                logger.warning("Revert after a rejected conversation action failed (\(Self.code(for: revertError), privacy: .public))")
            }
            throw error
        }
        // A 200 with `affected: 0` is the server saying the action matched no
        // message — a conversation-level `archive` only moves inbox/catchall
        // messages, so from Trash it is a no-op (upstream
        // conversation-queries.ts:190-192). The optimistic move has to come back
        // NOW: waiting for sync to heal it means the thread is missing from both
        // folders in the meantime, and forever if sync is unhealthy.
        guard result.affected > 0 else {
            logger.warning(
                "Conversation action \(action.rawValue, privacy: .public) affected no messages in \(folder.rawValue, privacy: .public); reverting the optimistic change"
            )
            // Best-effort revert: not rethrown (an affected:0 result is not an error
            // to the caller), but a revert failure is logged rather than swallowed.
            do {
                try await revert(undo)
            } catch let revertError {
                logger.warning("Revert of a no-op conversation action failed (\(Self.code(for: revertError), privacy: .public))")
            }
            return
        }
        // `POST /conversations/{id}/{action}` reports only a thread id and a
        // count, so there is no authoritative summary to write back — the fence
        // simply comes down and the journal supplies the server's timestamps.
        do {
            try await store.completeLocalAction(undo)
        } catch {
            logger.error("Confirmed action could not be recorded: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Applies a MESSAGE action to every message of a thread, one POST each.
    ///
    /// Herald used this to fake a "put back" out of Trash before upstream 1.3.4
    /// added `restore`/`unarchive`; the UI now uses the conversation route for
    /// that. Kept as the general escape hatch for any action the conversation
    /// route scopes more narrowly than the message route does.
    ///
    /// Each message goes through the single-message path, so each gets its own
    /// pending fence and its own revert; the first failure is what the caller
    /// sees, after every message has been attempted.
    public func perform(
        _ action: MessageAction,
        onMessagesOfThread threadID: String,
        accountID: String
    ) async throws {
        let messages = try await store.messages(accountID: accountID, threadID: threadID)
        guard !messages.isEmpty else { throw MailAPIError.notFound }
        var firstFailure: (any Error)?
        for message in messages {
            do {
                try await perform(action, on: message.id, accountID: accountID)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }

    // MARK: - Labels

    /// Adds or removes one label on a whole thread, optimistically.
    ///
    /// Same shape as the triage actions: the cache moves first, the request
    /// follows, and a rejection reverts EXACTLY the rows the optimistic write
    /// created.
    ///
    /// On success only the TOGGLED label is settled across the thread, from
    /// `result.assigned`. The answer's `labels` is deliberately NOT written: for
    /// a conversation it is the DISTINCT UNION across every accessible message of
    /// the thread, which is not any one message's set — writing it onto a message
    /// row would hand that message labels only its siblings carry, and strip ones
    /// it holds alone.
    public func setLabel(
        _ labelID: String,
        onConversation threadID: String,
        accountID: String,
        assigned: Bool,
        representativeMessageID: String? = nil
    ) async throws {
        // The conversation routes take a MESSAGE id, exactly like the triage ones
        // (the server derives the thread and does its access check from it).
        let cached = try await store.messages(accountID: accountID, threadID: threadID)
            .max(by: { ($0.receivedAt ?? $0.sentAt ?? .distantPast) < ($1.receivedAt ?? $1.sentAt ?? .distantPast) })
            .map(\.id)
        guard let representative = cached ?? representativeMessageID else {
            throw MailAPIError.notFound
        }
        let undo = try await store.applyLocalLabel(
            labelID, threadID: threadID, accountID: accountID, assigned: assigned
        )
        let result: LabelAssignment
        do {
            result = try await api.setLabel(labelID, onConversation: representative, assigned: assigned)
        } catch {
            logger.warning(
                "Label change on a conversation was rejected (\(Self.code(for: error), privacy: .public)); reverting: \(error.localizedDescription, privacy: .private)"
            )
            do {
                try await revert(undo)
            } catch let revertError {
                logger.warning("Revert after a rejected label change failed (\(Self.code(for: revertError), privacy: .public))")
            }
            throw error
        }
        // `affected: 0` here is NOT the no-op the triage actions have to undo: the
        // server answers 0 when every accessible message already had (or already
        // lacked) the label, and the optimistic write agrees with that outcome.
        // The authoritative set below is what settles it either way.
        do {
            try await store.settleThreadLabel(
                labelID, threadID: threadID, accountID: accountID, assigned: result.assigned
            )
        } catch {
            logger.error("Confirmed label change could not be recorded: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// The same, for one message.
    public func setLabel(
        _ labelID: String,
        onMessage messageID: String,
        accountID: String,
        assigned: Bool
    ) async throws {
        let undo = try await store.applyLocalLabel(
            labelID, messageID: messageID, accountID: accountID, assigned: assigned
        )
        let result: LabelAssignment
        do {
            result = try await api.setLabel(labelID, onMessage: messageID, assigned: assigned)
        } catch {
            logger.warning(
                "Label change on a message was rejected (\(Self.code(for: error), privacy: .public)); reverting: \(error.localizedDescription, privacy: .private)"
            )
            do {
                try await revert(undo)
            } catch let revertError {
                logger.warning("Revert after a rejected label change failed (\(Self.code(for: revertError), privacy: .public))")
            }
            throw error
        }
        do {
            try await store.setMessageLabels(
                result.labels.map(\.id), messageID: messageID, accountID: accountID
            )
        } catch {
            logger.error("Confirmed label change could not be recorded: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    private func revert(_ undo: LabelActionUndo) async throws {
        do {
            try await store.revertLocalLabel(undo)
        } catch {
            logger.error("Label revert failed; cache will heal on the next sweep: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// The revert is best-effort by design: the original API error is what the
    /// caller needs, and a failed revert is logged here rather than masking it.
    private func revert(_ undo: LocalActionUndo) async throws {
        do {
            try await store.revertLocalAction(undo)
        } catch {
            logger.error("Revert failed; cache will heal on next sync: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }
}

nonisolated extension MailActionService {
    /// A payload-free tag for the public part of a log line. Server messages can
    /// echo recipients or subjects, so the description itself is always private.
    static func code(for error: any Error) -> String {
        (error as? MailAPIError)?.logCode ?? String(describing: type(of: error))
    }
}
