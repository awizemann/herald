import Foundation
import Testing
@testable import HeraldKit

@Suite struct AccountTokenProviderTests {
    private let accountID = "https://mail.test.invalid"

    private func store(
        expiresIn: TimeInterval,
        refreshToken: String? = "refresh-0"
    ) throws -> RecordingAccountStore {
        let store = RecordingAccountStore()
        try store.setTokens(
            OAuthTokens(
                accessToken: "access-0",
                refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(expiresIn),
                scope: "mail:read offline_access"
            ),
            for: accountID
        )
        store.resetCounters()
        return store
    }

    /// Fails if the provider refreshes eagerly (burning a rotated refresh token on
    /// every call) instead of using the cached token.
    @Test("a token well inside its lifetime is returned without refreshing")
    func freshTokenIsReused() async throws {
        let store = try store(expiresIn: 3600)
        let refresher = GatedRefresher.counting()
        let provider = AccountTokenProvider(accountID: accountID, store: store, refresher: refresher)

        #expect(try await provider.accessToken() == "access-0")
        #expect(await refresher.callCount == 0)
    }

    /// The 60-second leeway is the point: a token that is technically still valid but
    /// expires in 30s must be refreshed, or an in-flight request dies mid-sync.
    /// Fails if the leeway is dropped or applied with the wrong sign.
    @Test("a token expiring inside the 60s leeway is refreshed and persisted")
    func nearExpiryTokenIsRefreshed() async throws {
        let store = try store(expiresIn: 30)
        let refresher = GatedRefresher.counting()
        let provider = AccountTokenProvider(accountID: accountID, store: store, refresher: refresher)

        #expect(try await provider.accessToken() == "access-1")
        #expect(await refresher.callCount == 1)
        #expect(await refresher.refreshTokensSeen == ["refresh-0"])
        // Persisted, so the next launch does not re-refresh.
        #expect(try store.tokens(for: accountID)?.accessToken == "access-1")
        #expect(try store.tokens(for: accountID)?.refreshToken == "refresh-1")

        // And the freshly stored token is then reused.
        #expect(try await provider.accessToken() == "access-1")
        #expect(await refresher.callCount == 1)
    }

    /// The core race. Five callers hit an expired token at once; the refresh is held
    /// open until all five are provably inside the provider (each has read the store,
    /// which happens with no suspension before joining or starting the refresh).
    /// Fails on any implementation that does not share one in-flight refresh — and
    /// with HQBase rotating refresh tokens, a second concurrent refresh would redeem
    /// an already-rotated grant and sign the account out.
    ///
    /// Time-limited because the failure mode is a hang, not a wrong value: a
    /// provider that loses a continuation leaves the task group waiting forever.
    @Test(
        "five concurrent accessToken() calls on an expired token trigger exactly one refresh",
        .timeLimit(.minutes(1))
    )
    func concurrentRefreshIsSerialized() async throws {
        let store = try store(expiresIn: -10)
        let refresher = GatedRefresher.counting(released: false)
        let provider = AccountTokenProvider(accountID: accountID, store: store, refresher: refresher)

        let releaser = Task {
            await store.waitForTokenReads(5)
            await refresher.release()
        }

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 {
                group.addTask { try await provider.accessToken() }
            }
            var collected: [String] = []
            for try await token in group { collected.append(token) }
            return collected
        }
        await releaser.value

        #expect(tokens == Array(repeating: "access-1", count: 5))
        #expect(await refresher.callCount == 1)
        // One refresh means one write, not five. (How many times the store was
        // READ is an implementation detail — the gate above already depends on it.)
        #expect(store.writes == 1)
    }

    /// Fails if `invalid_grant` is reported as a generic server error — the UI keys
    /// its "sign in again" prompt off this case, and a retry loop on a dead grant is
    /// the classic symptom.
    @Test("invalid_grant on refresh becomes .reauthenticationRequired and clears the dead tokens")
    func invalidGrantRequiresReauthentication() async throws {
        let store = try store(expiresIn: -10)
        let refresher = GatedRefresher.failing(
            with: OAuthError.server(error: "invalid_grant", description: "Token revoked")
        )
        let provider = AccountTokenProvider(accountID: accountID, store: store, refresher: refresher)

        await #expect(throws: OAuthError.reauthenticationRequired) {
            _ = try await provider.accessToken()
        }
        #expect(try store.tokens(for: accountID) == nil)
    }

    /// Fails if a transient network failure is misreported as re-auth, which would
    /// sign the user out every time the Wi-Fi blips.
    @Test("a transport failure on refresh is NOT reported as reauthenticationRequired")
    func transportFailureIsNotReauthentication() async throws {
        let store = try store(expiresIn: -10)
        let failure = OAuthError.transport(MailAPIError.TransportFailure(URLError(.notConnectedToInternet)))
        let provider = AccountTokenProvider(
            accountID: accountID,
            store: store,
            refresher: GatedRefresher.failing(with: failure)
        )

        await #expect(throws: failure) { _ = try await provider.accessToken() }
        // Tokens survive so a later retry can succeed.
        #expect(try store.tokens(for: accountID)?.accessToken == "access-0")
    }

    /// Fails if an account that never got `offline_access` silently returns a stale
    /// token forever instead of asking for a typed error.
    @Test("refreshing without a refresh token throws .missingRefreshToken")
    func missingRefreshTokenIsTyped() async throws {
        let store = try store(expiresIn: -10, refreshToken: nil)
        let provider = AccountTokenProvider(
            accountID: accountID,
            store: store,
            refresher: GatedRefresher.counting()
        )

        await #expect(throws: OAuthError.missingRefreshToken) { _ = try await provider.accessToken() }
    }

    /// The middleware's post-401 path. Fails if `refreshAccessToken()` short-circuits
    /// on a not-yet-expired token — the server has already rejected it.
    @Test("refreshAccessToken() refreshes even when the cached token has not expired")
    func explicitRefreshIgnoresExpiry() async throws {
        let store = try store(expiresIn: 3600)
        let refresher = GatedRefresher.counting()
        let provider = AccountTokenProvider(accountID: accountID, store: store, refresher: refresher)

        #expect(try await provider.refreshAccessToken(failedToken: "access-0") == "access-1")
        #expect(await refresher.callCount == 1)
    }

    /// Requests overlap, so a 401 for a token that has ALREADY been replaced keeps
    /// arriving after the refresh that replaced it. Fails on a provider that
    /// refreshes on every 401 regardless: with HQBase rotating refresh tokens, the
    /// second refresh redeems a spent grant and signs the account out.
    @Test("a late 401 carrying the superseded token does not refresh again")
    func staleUnauthorizedDoesNotRefreshTwice() async throws {
        let store = try store(expiresIn: -10)
        let refresher = GatedRefresher.counting()
        let provider = AccountTokenProvider(accountID: accountID, store: store, refresher: refresher)

        // First 401: the token we sent is the stored one, so this refreshes.
        #expect(try await provider.refreshAccessToken(failedToken: "access-0") == "access-1")
        #expect(await refresher.callCount == 1)

        // A request that was already in flight now reports its own 401, for the
        // token it used — the one we just replaced.
        #expect(try await provider.refreshAccessToken(failedToken: "access-0") == "access-1")
        #expect(await refresher.callCount == 1, "The stale 401 burned a second refresh token")
    }
}

/// Two Herald processes (the release app and a dev copy) share ONE Keychain token
/// item. HQBase's authorization server rotates the refresh token on every use with no
/// reuse grace, and replaying a rotated token invalidates the whole family — so the
/// second process does not merely fail, it signs BOTH processes out.
///
/// Modelled as two ``AccountTokenProvider``s over one ``SharedKeychain``, with one of
/// them reading through a ``StaleReadingStore`` so the "I read the item just before
/// the other process rotated it" interleaving is reproduced without threads or sleeps.
@Suite struct SharedKeychainRefreshRaceTests {
    private let accountID = "https://mail.test.invalid"

    /// The tokens both processes start from: expired, so both want to refresh.
    private func expiredTokens() -> OAuthTokens {
        OAuthTokens(
            accessToken: "access-0",
            refreshToken: "refresh-0",
            expiresAt: Date().addingTimeInterval(-10),
            scope: "mail:read offline_access"
        )
    }

    /// A fixed leeway keeps these tests independent of the jitter in (e).
    private func provider(
        store: any AccountStore,
        refresher: any TokenRefreshing
    ) -> AccountTokenProvider {
        AccountTokenProvider(accountID: accountID, store: store, refresher: refresher, refreshLeeway: 60)
    }

    /// (a) Fails today: B holds tokens it read before A's rotation landed, so it POSTs
    /// `grant_type=refresh_token` with the already-rotated `refresh-0`, gets
    /// `invalid_grant`, and takes the shared item down with it. The fix is to re-read
    /// the store immediately before spending the grant.
    @Test("a provider whose tokens were rotated by another process adopts them instead of refreshing")
    func staleProviderAdoptsRotatedTokensWithoutRefreshing() async throws {
        let keychain = SharedKeychain()
        let stale = expiredTokens()
        try keychain.seed(stale, for: accountID)
        let refresher = RotatingRefresher()

        let a = provider(store: keychain.store, refresher: refresher)
        let bStore = StaleReadingStore(keychain.store)
        let b = provider(store: bStore, refresher: refresher)

        // Process A refreshes for real: refresh-0 is now revoked server-side.
        #expect(try await a.accessToken() == "access-1")

        // Process B's first read landed before A's write.
        bStore.serveStale(stale)
        #expect(try await b.accessToken() == "access-1")
        #expect(refresher.sentTokens == ["refresh-0"], "B replayed the rotated refresh token")
        #expect(try keychain.store.tokens(for: accountID)?.refreshToken == "refresh-1")
    }

    /// (b) Fails today: `invalid_grant` unconditionally deletes the shared item, so the
    /// process that legitimately rotated the grant finds "no refresh token" on its next
    /// call. B must notice the store no longer holds the token that was rejected.
    @Test("invalid_grant for a token another process already rotated adopts the new tokens instead of clearing")
    func staleInvalidGrantAdoptsRatherThanClears() async throws {
        let keychain = SharedKeychain()
        let stale = expiredTokens()
        try keychain.seed(stale, for: accountID)
        let refresher = RotatingRefresher()

        let a = provider(store: keychain.store, refresher: refresher)
        let bStore = StaleReadingStore(keychain.store)
        let b = provider(store: bStore, refresher: refresher)

        #expect(try await a.accessToken() == "access-1")

        // Both of B's reads before the POST see the pre-rotation snapshot, so B really
        // does send the revoked token and really does get invalid_grant.
        bStore.serveStale(stale)
        bStore.serveStale(stale)

        #expect(try await b.accessToken() == "access-1")
        #expect(refresher.sentTokens == ["refresh-0", "refresh-0"])
        #expect(bStore.pendingStaleReads == 0, "B never reached the post-rejection re-read")
        // The item A depends on survived.
        #expect(try keychain.store.tokens(for: accountID)?.accessToken == "access-1")
        #expect(try keychain.store.tokens(for: accountID)?.refreshToken == "refresh-1")
    }

    /// (c) Regression guard for (b): when the store still holds the very token the
    /// server rejected, nobody rotated anything and the grant really is dead. Fails if
    /// the (b) fix is written as "never clear on invalid_grant", which would leave the
    /// user stuck retrying a dead grant forever.
    @Test("invalid_grant with no competing rotation still clears the tokens and demands re-auth")
    func genuineInvalidGrantStillRequiresReauthentication() async throws {
        let keychain = SharedKeychain()
        try keychain.seed(expiredTokens(), for: accountID)
        // The server considers this grant dead before we even start.
        let refresher = RotatingRefresher(revoked: ["refresh-0"])
        let p = provider(store: keychain.store, refresher: refresher)

        await #expect(throws: OAuthError.reauthenticationRequired) { _ = try await p.accessToken() }
        #expect(refresher.sentTokens == ["refresh-0"])
        #expect(try keychain.store.tokens(for: accountID) == nil)
    }

    /// (d) Fails today twice over: there is no retry after a 5xx at all, and a retry
    /// that resends the buffered token would replay a grant another process rotated in
    /// exactly the window the 500 opened.
    @Test("a retry after a 5xx re-reads the store and adopts, instead of resending the same refresh token")
    func retryAfterServerErrorReReadsTheStore() async throws {
        let keychain = SharedKeychain()
        try keychain.seed(expiredTokens(), for: accountID)
        let accountID = accountID
        let store = keychain.store
        let rotated = OAuthTokens(
            accessToken: "access-9",
            refreshToken: "refresh-9",
            expiresAt: Date().addingTimeInterval(3600),
            scope: "mail:read offline_access"
        )

        let refresher = RotatingRefresher { index, refresher in
            guard index == 1 else { return }
            // The other process completes its refresh in the window our 500 opens.
            refresher.revoke("refresh-0")
            try store.setTokens(rotated, for: accountID)
            throw OAuthError.server(error: "http_500", description: nil)
        }
        let p = provider(store: keychain.store, refresher: refresher)

        #expect(try await p.accessToken() == "access-9")
        #expect(refresher.sentTokens == ["refresh-0"], "The retry replayed the rotated refresh token")
        #expect(try keychain.store.tokens(for: accountID)?.refreshToken == "refresh-9")
    }

    /// (e) Fails on a fixed 60s leeway: two processes holding one token would decide to
    /// refresh at the same instant on every cycle, which is what turns the race from
    /// rare into constant.
    @Test("the proactive refresh window is jittered inside [60, 180] and stays injectable")
    func refreshLeewayIsJitteredAndInjectable() {
        let keychain = SharedKeychain()
        let refresher = RotatingRefresher()
        let drawn = (0..<50).map { _ in
            AccountTokenProvider(accountID: accountID, store: keychain.store, refresher: refresher).refreshLeeway
        }

        #expect(drawn.allSatisfy { OAuthTokens.refreshLeewayRange.contains($0) })
        #expect(Set(drawn).count > 1, "Every provider woke on the same schedule")
        #expect(provider(store: keychain.store, refresher: refresher).refreshLeeway == 60)
    }
}
