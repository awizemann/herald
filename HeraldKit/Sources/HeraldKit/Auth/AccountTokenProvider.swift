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
///
/// It is also the ONE place that decides "this account's session is dead" short of
/// `invalid_grant`: a refreshable 401 for a token this provider just handed out
/// (reported through ``sessionRejected(token:)``) latches the grant, and every
/// later call fails fast with ``OAuthError/reauthenticationRequired`` instead of
/// spending the rotating refresh token again. See ``deadGrant``.
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

    /// The grant (``grantKey(_:)``) a server has refused even after a refresh.
    ///
    /// Keyed to the GRANT, never to this provider's lifetime: the store is the
    /// arbiter, so the moment it holds a different grant (a re-auth landed — in
    /// this graph, a newer one, or another process) the latch no longer matches
    /// and those tokens are served. That is what lets a component still holding
    /// a superseded graph's provider (an open composer's outbox) keep working
    /// after the user signs back in. In memory only: the Keychain item is NOT
    /// cleared here (unlike `invalid_grant`) — on a 1.4.2 server the refresh
    /// token may well be fine, and re-auth overwrites it anyway.
    private var deadGrant: String?

    /// Told once per dead grant, after it is latched. See
    /// ``setSessionRejectedHandler(_:)``.
    private var sessionRejectedHandler: (@Sendable (Account.ID) async -> Void)?

    /// The grant (``grantKey(_:)``) whose death was last announced, or
    /// ``emptyStoreKey`` for "no grant stored at all".
    ///
    /// Separate from ``deadGrant`` because not every death is a latch: an
    /// `invalid_grant` clears the item instead, and a grant with no refresh
    /// token simply cannot be renewed. All three announce through the one
    /// handler, and this is what keeps that to ONCE per grant however many
    /// requests trip over it. Forgotten as soon as the store holds a grant other
    /// than the announced one — see ``observe(_:)``.
    private var announcedDeath: String?

    /// Stands in for "the store holds nothing" in ``announcedDeath``. Not a
    /// possible grant key: real refresh and access tokens are never empty.
    private static let emptyStoreKey = ""

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

    /// Installs (or, with `nil`, removes) the hook told when a grant is found dead.
    ///
    /// The ONE dead-session signal for the app: a grant refused after a refresh
    /// (``sessionRejected(token:)``), a refresh answered `invalid_grant`, and a
    /// refresh that has no refresh token to spend all announce here — whichever
    /// request tripped over it (sync, a send, a draft autosave, a message open).
    ///
    /// Settable after construction because the provider is built
    /// (``AuthCoordinator/tokenProvider(for:)``) before the app graph that routes
    /// the signal exists. Called with the account id, once per dead grant, and
    /// AWAITED — so it runs before the request that discovered the death returns
    /// its `.unauthorized`. The actor is re-entrant across that await: a handler
    /// may call straight back into this provider without deadlocking.
    ///
    /// The handler MUST return promptly and start any long work (the re-auth
    /// attempt) in its own `Task`, like the app's other expiry callbacks: the
    /// request or socket loop that reported the death is suspended until it
    /// returns. In particular it must never await `MailEventSocket.stop()` — the
    /// socket's loop is one of the reporters, so that wait is a deadlock.
    public func setSessionRejectedHandler(_ handler: (@Sendable (Account.ID) async -> Void)?) {
        sessionRejectedHandler = handler
    }

    public func accessToken() async throws -> String {
        // This read and the `refreshTask` check below happen with no suspension in
        // between, so a caller either starts the refresh or joins the existing one.
        let stored = try store.tokens(for: accountID)
        observe(stored)
        try checkLatch(against: stored)
        if let stored, stored.isUsable(at: now(), leeway: refreshLeeway) { return stored.accessToken }
        return try await refreshTokens(replacing: stored).accessToken
    }

    public func refreshAccessToken(failedToken: String) async throws -> String {
        let stored = try store.tokens(for: accountID)
        // Before the stale-401 shortcut too: a latched grant's access token is
        // dead however recently it was minted.
        observe(stored)
        try checkLatch(against: stored)
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

    /// Latches the grant `token` belongs to when the server refused it after a
    /// refresh. See ``BearerTokenProvider/sessionRejected(token:)``.
    ///
    /// Only when `token` is STILL the stored access token: if the store has moved
    /// on (another request or process refreshed, or a re-auth landed) the
    /// rejection is about a superseded token and says nothing about the live
    /// grant — the next request simply uses the new one.
    public func sessionRejected(token: String) async {
        let stored: OAuthTokens?
        do {
            stored = try store.tokens(for: accountID)
        } catch {
            // Cannot tell which grant is live, so latch nothing. Not a storm
            // risk: an unreadable store also aborts every refresh.
            logger.error("token store unreadable for \(self.accountID, privacy: .public); rejection not latched")
            return
        }
        guard let stored, stored.accessToken == token else {
            logger.warning("post-refresh 401 for \(self.accountID, privacy: .public) was for a superseded token; not latching")
            return
        }
        observe(stored)
        let grant = Self.grantKey(stored)
        // Latched and checked with no suspension in between, so concurrent
        // reports of the same death announce it exactly once.
        guard grant != deadGrant else { return }
        deadGrant = grant
        logger.warning("session rejected after refresh for \(self.accountID, privacy: .public); grant latched, re-auth required")
        await announceDeath(ofGrant: grant)
    }

    /// Tells the handler this account's session is dead, once per grant.
    ///
    /// - Parameter grant: the dead grant's ``grantKey(_:)``, or `nil` when the
    ///   store holds no grant at all. An empty store is announced only when no
    ///   death has been announced since the last live grant: it is usually the
    ///   AFTERMATH of an `invalid_grant` this provider already announced (that
    ///   path clears the item), and every later request finding it empty is the
    ///   same death, not a new one.
    ///
    /// Recorded BEFORE awaiting the handler: the actor is re-entrant across that
    /// await, and the concurrent requests that hit the same death must find it
    /// already announced.
    private func announceDeath(ofGrant grant: String?) async {
        if let grant {
            guard grant != announcedDeath else { return }
            announcedDeath = grant
        } else {
            guard announcedDeath == nil else { return }
            announcedDeath = Self.emptyStoreKey
        }
        await sessionRejectedHandler?(accountID)
    }

    /// Forgets the announced death once the store holds a DIFFERENT grant (a
    /// re-auth landed, here or in another process), so that grant's own death
    /// is announced again. An empty store forgets nothing — see
    /// ``announceDeath(ofGrant:)``.
    private func observe(_ stored: OAuthTokens?) {
        guard let announcedDeath, let stored, Self.grantKey(stored) != announcedDeath else { return }
        self.announcedDeath = nil
    }

    /// Throws when `stored` is the latched dead grant; clears a latch the store
    /// has moved past.
    private func checkLatch(against stored: OAuthTokens?) throws {
        guard let deadGrant, let stored else { return }
        if Self.grantKey(stored) == deadGrant {
            throw OAuthError.reauthenticationRequired
        }
        logger.info("a new grant replaced the rejected one for \(self.accountID, privacy: .public); latch cleared")
        self.deadGrant = nil
    }

    /// Identifies a grant. The refresh token is what rotates with it; an access
    /// token stands in only for a grant that never had one.
    private nonisolated static func grantKey(_ tokens: OAuthTokens) -> String {
        tokens.refreshToken ?? tokens.accessToken
    }

    // MARK: - Refresh

    private func refreshTokens(replacing stale: OAuthTokens?) async throws -> OAuthTokens {
        if let refreshTask { return try await refreshTask.value }

        guard let stale, let refreshToken = stale.refreshToken else {
            logger.warning("no refresh token for account \(self.accountID, privacy: .public)")
            // Nothing to renew with, so only a fresh sign-in helps: a dead
            // session like any other, announced like one.
            await announceDeath(ofGrant: stale.map(Self.grantKey))
            throw OAuthError.missingRefreshToken
        }

        let task = Task<OAuthTokens, any Error> { [self] in
            try await performRefresh(replacing: stale)
        }
        refreshTask = task

        defer { refreshTask = nil }
        do {
            return try await task.value
        } catch OAuthError.reauthenticationRequired {
            // `performRefresh` throws this only for an `invalid_grant` that was
            // NOT the echo of somebody else's rotation — the refresh token it
            // spent is dead (and the item already cleared). Announced here, by
            // the one caller that started the refresh, rather than inside the
            // nonisolated body: `announceDeath` is actor state. Callers that
            // JOINED the task get the same error without announcing again.
            // While this awaits the handler `refreshTask` is still set, so a
            // request arriving meanwhile joins the failed task and fails too.
            await announceDeath(ofGrant: refreshToken)
            throw OAuthError.reauthenticationRequired
        }
    }

    /// The refresh body. `nonisolated` so it runs inside the shared `Task` without
    /// re-entering the actor on every step — everything it touches is an immutable
    /// `Sendable` `let`, and the store is its own synchronization point.
    private nonisolated func performRefresh(replacing stale: OAuthTokens) async throws -> OAuthTokens {
        let sending = stale

        for attempt in 1...Self.maxRefreshAttempts {
            // (1) Re-read and compare BEFORE spending the grant. Between deciding to
            // refresh and getting here, another process may have rotated it.
            // OUTSIDE the `do` on purpose: a store that cannot be read must abort
            // the refresh rather than be retried into spending the grant blind.
            if let rotated = try rotatedTokens(past: sending) {
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
                // `try?` HERE, and only here: the write above already succeeded,
                // so `fresh` is a live grant we own. This read is the optional
                // "did somebody land after us" confirmation — throwing on it
                // would send the caller back around the loop to spend the token
                // we just minted. The failure is still logged by `currentTokens`.
                if let newer = try? rotatedTokens(past: fresh) {
                    logger.warning("newer tokens landed for \(self.accountID, privacy: .public); adopting them over ours")
                    return newer
                }
                return fresh
            } catch let error as OAuthError where error.isInvalidGrant {
                // (2) invalid_grant may just mean "another process rotated this grant
                // first". Destroying the item would strand THAT process too.
                // Throws (rather than assuming "no competing rotation") when the
                // store cannot be read: without that read there is no way to tell
                // a dead grant from somebody else's successful rotation, and
                // clearing the item on a guess strands the other process too.
                if let rotated = try tokens(replacing: refreshToken) {
                    logger.warning("invalid_grant for \(self.accountID, privacy: .public) was stale; adopting the rotated tokens")
                    return rotated
                }
                logger.warning("refresh rejected for \(self.accountID, privacy: .public); re-auth required")
                // The grant really is dead; drop it so nothing retries with it.
                do {
                    try store.setTokens(nil, for: accountID)
                } catch {
                    // Not fatal — the caller is being sent to re-auth either way —
                    // but a clear that silently failed leaves a dead grant on disk
                    // for the next launch to retry, which is worth seeing in a log.
                    logger.error("could not clear the dead grant for \(self.accountID, privacy: .public)")
                }
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

    /// The stored tokens, or `nil` when the store genuinely holds none.
    ///
    /// A read FAILURE is not "nothing stored" and must never be flattened into
    /// it: the Keychain is the arbiter of which grant is live, so a caller that
    /// treated an unreadable item as an empty one would go on to spend a refresh
    /// token another process may have already rotated — and replaying a rotated
    /// token invalidates the whole family. The error is logged here and thrown so
    /// the refresh aborts; it is `.transport`, hence retryable, because the grant
    /// itself is very probably still good.
    private nonisolated func currentTokens() throws -> OAuthTokens? {
        do {
            return try store.tokens(for: accountID)
        } catch {
            logger.error("token store unreadable for \(self.accountID, privacy: .public); refresh aborted")
            throw OAuthError.transport(MailAPIError.TransportFailure(error))
        }
    }

    /// The stored tokens when another process has moved past `ours`, else `nil`.
    ///
    /// "Moved past" is a different refresh token (the grant was rotated), or a
    /// different access token that is itself still usable (rotated, and the new
    /// access token is good enough to use as-is).
    ///
    /// Throws when the store could not be read — see ``currentTokens()``.
    private nonisolated func rotatedTokens(past ours: OAuthTokens) throws -> OAuthTokens? {
        guard let stored = try currentTokens() else { return nil }
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
    private nonisolated func tokens(replacing rejected: String) throws -> OAuthTokens? {
        guard let stored = try currentTokens(), stored.refreshToken != rejected else { return nil }
        return stored
    }
}
