import Foundation
import HeraldKit

/// Hands out scripted access tokens and counts refreshes.
///
/// An actor so the refresh counter is race-free; `BearerTokenProvider` is
/// `nonisolated` precisely so this can conform.
actor FakeTokenProvider: BearerTokenProvider {
    private var current: String
    private var refreshed: [String]
    private(set) var accessTokenCallCount = 0
    private(set) var refreshCallCount = 0
    /// When set, `refreshAccessToken()` throws it instead of returning a token.
    var refreshFailure: (any Error)?

    /// - Parameters:
    ///   - initial: the first access token handed out.
    ///   - refreshedTokens: tokens returned by successive refreshes (last repeats).
    init(initial: String = "token-1", refreshedTokens: [String] = ["token-2"]) {
        self.current = initial
        self.refreshed = refreshedTokens
    }

    func accessToken() async throws -> String {
        accessTokenCallCount += 1
        return current
    }

    func refreshAccessToken() async throws -> String {
        refreshCallCount += 1
        if let refreshFailure { throw refreshFailure }
        current = refreshed[min(refreshCallCount - 1, refreshed.count - 1)]
        return current
    }

    func setRefreshFailure(_ error: any Error) {
        refreshFailure = error
    }
}

/// In-memory ``SecretStore`` so Keychain-backed code is testable without the
/// system Keychain (and without entitlements in `swift test`).
nonisolated final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func data(for key: String) throws -> Data? { lock.withLock { storage[key] } }
    func set(_ data: Data, for key: String) throws { lock.withLock { storage[key] = data } }
    func removeValue(for key: String) throws { lock.withLock { storage[key] = nil } }
}
