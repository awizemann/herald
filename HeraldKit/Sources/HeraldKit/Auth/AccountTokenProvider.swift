import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "oauth")

/// Supplies the bearer token for one account to ``AuthenticatingMiddleware``.
///
/// An actor because refresh MUST be serialized: sync, compose and the UI can all hit
/// an expired token in the same millisecond, and HQBase rotates the refresh token on
/// use — a second concurrent refresh would redeem an already-rotated grant and log
/// the account out. Concurrent callers therefore share one in-flight `Task`.
public actor AccountTokenProvider: BearerTokenProvider {
    private let accountID: Account.ID
    private let store: any AccountStore
    private let refresher: any TokenRefreshing
    /// Injected so tests get deterministic expiry without waiting.
    private let now: @Sendable () -> Date

    /// Shared by every caller that arrives while a refresh is in flight.
    private var refreshTask: Task<OAuthTokens, any Error>?

    public init(
        accountID: Account.ID,
        store: any AccountStore,
        refresher: any TokenRefreshing,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.accountID = accountID
        self.store = store
        self.refresher = refresher
        self.now = now
    }

    public func accessToken() async throws -> String {
        // This read and the `refreshTask` check below happen with no suspension in
        // between, so a caller either starts the refresh or joins the existing one.
        let stored = try store.tokens(for: accountID)
        if let stored, stored.isUsable(at: now()) { return stored.accessToken }
        return try await refreshTokens(from: stored).accessToken
    }

    public func refreshAccessToken(failedToken: String) async throws -> String {
        let stored = try store.tokens(for: accountID)
        // The 401 was for a token we have since replaced: a concurrent request
        // already refreshed. Refreshing again would redeem an already-rotated
        // refresh token and sign the account out.
        if let stored, stored.accessToken != failedToken {
            logger.warning("stale 401 for \(self.accountID, privacy: .public); reusing the refreshed token")
            return stored.accessToken
        }
        return try await refreshTokens(from: stored).accessToken
    }

    private func refreshTokens(from stored: OAuthTokens?) async throws -> OAuthTokens {
        if let refreshTask { return try await refreshTask.value }

        guard let refreshToken = stored?.refreshToken else {
            logger.warning("no refresh token for account \(self.accountID, privacy: .public)")
            throw OAuthError.missingRefreshToken
        }

        let refresher = self.refresher
        let store = self.store
        let accountID = self.accountID
        let task = Task<OAuthTokens, any Error> {
            do {
                var tokens = try await refresher.refresh(refreshToken: refreshToken)
                // A server that omits refresh_token on rotation means "keep the old one".
                if tokens.refreshToken == nil { tokens.refreshToken = refreshToken }
                try store.setTokens(tokens, for: accountID)
                return tokens
            } catch let error as OAuthError where error.isInvalidGrant {
                logger.warning("refresh rejected for \(accountID, privacy: .public); re-auth required")
                // The grant is dead; drop it so nothing retries with it.
                try? store.setTokens(nil, for: accountID)
                throw OAuthError.reauthenticationRequired
            } catch {
                logger.error("refresh failed for \(accountID, privacy: .public)")
                throw OAuthError.wrapTransport(error)
            }
        }
        refreshTask = task

        defer { refreshTask = nil }
        return try await task.value
    }
}
