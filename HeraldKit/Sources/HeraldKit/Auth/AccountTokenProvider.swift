import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "oauth")

/// Supplies the bearer token for one account to ``AuthenticatingMiddleware``.
///
/// An actor because refresh MUST be serialized: sync, compose and the UI can all hit
/// an expired token in the same millisecond, and HQBase rotates the refresh token on
/// use — a second concurrent refresh would redeem an already-rotated grant and log
/// the account out. Concurrent callers therefore share one in-flight `Task`.
///
/// The actor only serializes refreshes *inside one process*. Two Herald processes
/// (release app + a dev copy) share one Keychain item, and HQBase's authorization
/// server rotates the refresh token on every use with **no reuse grace**: replaying a
/// rotated token invalidates the whole family. So the Keychain — not memory — is the
/// arbiter. Every point where this type is about to spend a refresh token, and every
/// point where one was rejected, re-reads the store first and adopts whatever another
/// process already rotated in. See ``rotatedTokens(past:)``.
public actor AccountTokenProvider: BearerTokenProvider {
    private let accountID: Account.ID
    private let store: any AccountStore
    private let refresher: any TokenRefreshing
    /// Injected so tests get deterministic expiry without waiting.
    private let now: @Sendable () -> Date

    /// How long before actual expiry this provider proactively refreshes. Drawn once,
    /// per provider, from ``OAuthTokens/refreshLeewayRange`` so two processes holding
    /// the same token do not wake at the same instant. Injectable for tests.
    public nonisolated let refreshLeeway: TimeInterval

    /// Shared by every caller that arrives while a refresh is in flight.
    private var refreshTask: Task<OAuthTokens, any Error>?

    /// One retry, only for transport/5xx — and only after re-reading the store.
    private static let maxRefreshAttempts = 2

    public init(
        accountID: Account.ID,
        store: any AccountStore,
        refresher: any TokenRefreshing,
        refreshLeeway: TimeInterval = OAuthTokens.jitteredRefreshLeeway(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.accountID = accountID
        self.store = store
        self.refresher = refresher
        self.refreshLeeway = refreshLeeway
        self.now = now
    }

    public func accessToken() async throws -> String {
        // This read and the `refreshTask` check below happen with no suspension in
        // between, so a caller either starts the refresh or joins the existing one.
        let stored = try store.tokens(for: accountID)
        if let stored, stored.isUsable(at: now(), leeway: refreshLeeway) { return stored.accessToken }
        return try await refreshTokens(replacing: stored).accessToken
    }

    public func refreshAccessToken(failedToken: String) async throws -> String {
        let stored = try store.tokens(for: accountID)
        // The 401 was for a token we have since replaced: a concurrent request — in
        // this process or another one — already refreshed. Refreshing again would
        // redeem an already-rotated refresh token and sign the account out. No
        // leeway here: the server just accepted or rejected this exact token, so
        // "not yet expired" is the only bar it has to clear.
        if let stored, stored.accessToken != failedToken, stored.isUsable(at: now(), leeway: 0) {
            logger.warning("stale 401 for \(self.accountID, privacy: .public); reusing the refreshed token")
            return stored.accessToken
        }
        return try await refreshTokens(replacing: stored).accessToken
    }

    // MARK: - Refresh

    private func refreshTokens(replacing stale: OAuthTokens?) async throws -> OAuthTokens {
        if let refreshTask { return try await refreshTask.value }

        guard let stale, stale.refreshToken != nil else {
            logger.warning("no refresh token for account \(self.accountID, privacy: .public)")
            throw OAuthError.missingRefreshToken
        }

        let task = Task<OAuthTokens, any Error> { [self] in
            try await performRefresh(replacing: stale)
        }
        refreshTask = task

        defer { refreshTask = nil }
        return try await task.value
    }

    /// The refresh body. `nonisolated` so it runs inside the shared `Task` without
    /// re-entering the actor on every step — everything it touches is an immutable
    /// `Sendable` `let`, and the store is its own synchronization point.
    private nonisolated func performRefresh(replacing stale: OAuthTokens) async throws -> OAuthTokens {
        let sending = stale

        for attempt in 1...Self.maxRefreshAttempts {
            // (1) Re-read and compare BEFORE spending the grant. Between deciding to
            // refresh and getting here, another process may have rotated it.
            if let rotated = rotatedTokens(past: sending) {
                logger.warning("adopting externally rotated tokens for \(self.accountID, privacy: .public); refresh skipped")
                return rotated
            }
            guard let refreshToken = sending.refreshToken else {
                logger.warning("no refresh token for account \(self.accountID, privacy: .public)")
                throw OAuthError.missingRefreshToken
            }

            do {
                var fresh = try await refresher.refresh(refreshToken: refreshToken)
                // A server that omits refresh_token on rotation means "keep the old one".
                if fresh.refreshToken == nil { fresh.refreshToken = refreshToken }
                // (3) Persist before returning, then confirm the store still holds OUR
                // tokens: a process that rotated while we were in flight wrote after us
                // only if its write landed later, and its grant is the live one.
                try store.setTokens(fresh, for: accountID)
                if let newer = rotatedTokens(past: fresh) {
                    logger.warning("newer tokens landed for \(self.accountID, privacy: .public); adopting them over ours")
                    return newer
                }
                return fresh
            } catch let error as OAuthError where error.isInvalidGrant {
                // (2) invalid_grant may just mean "another process rotated this grant
                // first". Destroying the item would strand THAT process too.
                if let rotated = tokens(replacing: refreshToken) {
                    logger.warning("invalid_grant for \(self.accountID, privacy: .public) was stale; adopting the rotated tokens")
                    return rotated
                }
                logger.warning("refresh rejected for \(self.accountID, privacy: .public); re-auth required")
                // The grant really is dead; drop it so nothing retries with it.
                try? store.setTokens(nil, for: accountID)
                throw OAuthError.reauthenticationRequired
            } catch {
                let oauth = OAuthError.wrapTransport(error)
                guard attempt < Self.maxRefreshAttempts, oauth.isRetryable else {
                    logger.error("refresh failed for \(self.accountID, privacy: .public)")
                    throw oauth
                }
                logger.warning("refresh attempt \(attempt, privacy: .public) failed for \(self.accountID, privacy: .public); re-reading the store before retrying")
                // Fall through to the top of the loop, which re-reads and compares
                // before spending the grant again: a 5xx is exactly the window in
                // which another process finishes its own refresh, and resending a
                // token it has already rotated is what kills the family.
            }
        }

        // Unreachable: the loop either returns or throws on its last attempt.
        throw OAuthError.reauthenticationRequired
    }

    // MARK: - Store arbitration

    private nonisolated func currentTokens() -> OAuthTokens? {
        (try? store.tokens(for: accountID)) ?? nil
    }

    /// The stored tokens when another process has moved past `ours`, else `nil`.
    ///
    /// "Moved past" is a different refresh token (the grant was rotated), or a
    /// different access token that is itself still usable (rotated, and the new
    /// access token is good enough to use as-is).
    private nonisolated func rotatedTokens(past ours: OAuthTokens) -> OAuthTokens? {
        guard let stored = currentTokens() else { return nil }
        if stored.refreshToken != ours.refreshToken { return stored }
        if stored.accessToken != ours.accessToken, stored.isUsable(at: now(), leeway: refreshLeeway) {
            return stored
        }
        return nil
    }

    /// The stored tokens when the store's refresh token is no longer `rejected` —
    /// i.e. our `invalid_grant` is the echo of somebody else's successful rotation.
    ///
    /// Deliberately stricter than ``rotatedTokens(past:)``: while the *rejected*
    /// refresh token is still the stored one, the whole family is dead no matter what
    /// the access token says.
    private nonisolated func tokens(replacing rejected: String) -> OAuthTokens? {
        guard let stored = currentTokens(), stored.refreshToken != rejected else { return nil }
        return stored
    }
}
