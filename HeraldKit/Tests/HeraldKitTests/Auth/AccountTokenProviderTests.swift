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
    @Test("five concurrent accessToken() calls on an expired token trigger exactly one refresh")
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
        #expect(store.tokenReadCount == 5)
        // One refresh means one write, not five.
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

        #expect(try await provider.refreshAccessToken() == "access-1")
        #expect(await refresher.callCount == 1)
    }
}
