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
    /// This is the only way to move a thread out of Trash: the v1 API has no
    /// restore/untrash action, and the CONVERSATION-level `archive` ignores
    /// messages that are not in inbox/catchall. The message route sets
    /// `folder = archived` from any folder, so "Move to Archive" in the Trash
    /// scope is N message calls rather than one conversation call.
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
