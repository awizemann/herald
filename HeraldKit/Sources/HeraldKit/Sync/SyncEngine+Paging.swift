import Foundation
import OSLog

/// Same subsystem and category as `SyncEngine.swift`: backfill is part of the
/// sync surface and its lines belong in the same stream.
private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "SyncEngine")

/// On-demand paging PAST what the sync pass caches.
///
/// A pass page-walks each (mailbox, folder) listing up to
/// ``SyncEngine/defaultMaxConversationPages`` and skips tombstoning when it hits
/// that cap. Below the cap the cache already holds the whole listing and the
/// view pages through it from the store; this is only for the listings the pass
/// stopped short on. It fetches ONE more server page per capped scope the view
/// is looking at, stores it (never tombstones), and remembers the next cursor.
///
/// Rows it adds survive later passes by construction: a pass that hits the cap
/// again skips tombstoning, and one that reaches the end has by then re-listed
/// every row the server still has.
extension SyncEngine {
    /// Fetches the next server page for every capped listing of `folder` among
    /// `mailboxIDs` (`nil` = every mailbox).
    ///
    /// - Returns: `true` while more server pages may remain for those listings
    ///   (the caller keeps offering "load more"), `false` once there is nothing
    ///   left to fetch — including the common case of no capped listing at all.
    /// - Throws: the first listing error. Cursors that failed are kept (except a
    ///   rejected one, which is dropped so the next capped pass can re-seed it),
    ///   so the caller simply retries on its next scroll.
    @discardableResult
    public func loadOlderConversations(mailboxIDs: Set<String>?, folder: ConversationFolder) async throws -> Bool {
        guard let accountID else { return false }
        let generation = passGeneration
        let targets = conversationResumeCursors.filter { scope, _ in
            scope.folder == folder && (mailboxIDs.map { ids in ids.contains(scope.mailboxID ?? "") } ?? true)
        }
        var firstError: (any Error)?
        for (scope, cursor) in targets {
            let page: ConversationPage
            do {
                page = try await api.listConversations(
                    folder: folder, mailboxID: scope.mailboxID, search: nil, cursor: cursor
                )
            } catch {
                if Self.isRejectedCursor(error), conversationResumeCursors[scope] == cursor {
                    conversationResumeCursors[scope] = nil
                }
                logger.warning("Conversation backfill failed: \(error.localizedDescription, privacy: .private)")
                firstError = firstError ?? error
                continue
            }
            // `stop()`/`start()` ran while the page was in flight: the store may
            // be about to be purged, or belong to a different session.
            guard generation == passGeneration, self.accountID == accountID else { throw CancellationError() }
            _ = try await store.upsertConversations(
                page.conversations, accountID: accountID, mailboxID: scope.mailboxID, folder: folder
            )
            guard generation == passGeneration else { throw CancellationError() }
            // Only advance the cursor we started from; a concurrent backfill of
            // the same scope that already went further keeps its position.
            if conversationResumeCursors[scope] == cursor {
                conversationResumeCursors[scope] = page.nextCursor
            }
        }
        if let firstError { throw firstError }
        return conversationResumeCursors.contains { scope, _ in
            scope.folder == folder && (mailboxIDs.map { ids in ids.contains(scope.mailboxID ?? "") } ?? true)
        }
    }

    private nonisolated static func isRejectedCursor(_ error: any Error) -> Bool {
        switch error as? MailAPIError {
        case .cursorExpired: return true
        case .server(let code, _): return code == "INVALID_CURSOR"
        default: return false
        }
    }
}
