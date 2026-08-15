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
        do {
            _ = try await api.perform(action, onMessage: messageID)
        } catch {
            logger.warning(
                "Message action \(action.rawValue, privacy: .public) rejected; reverting: \(error.localizedDescription, privacy: .public)"
            )
            try? await revert(undo)
            throw error
        }
    }

    /// Same contract for a whole thread. `folder` is required by the server on
    /// conversation actions (a missing folder is a 400).
    public func perform(
        _ action: ConversationAction,
        onConversation threadID: String,
        in folder: ConversationFolder,
        accountID: String
    ) async throws {
        let undo = try await store.applyLocalAction(action, threadID: threadID, accountID: accountID)
        do {
            _ = try await api.perform(action, onConversation: threadID, in: folder)
        } catch {
            logger.warning(
                "Conversation action \(action.rawValue, privacy: .public) rejected; reverting: \(error.localizedDescription, privacy: .public)"
            )
            try? await revert(undo)
            throw error
        }
    }

    /// The revert is best-effort by design: the original API error is what the
    /// caller needs, and a failed revert is logged here rather than masking it.
    private func revert(_ undo: LocalActionUndo) async throws {
        do {
            try await store.revertLocalAction(undo)
        } catch {
            logger.error("Revert failed; cache will heal on next sync: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
