import Foundation
import Testing
@testable import HeraldKit

/// A refresh persists its rotation ONLY over the grant it spent
/// (`AccountStore.setTokens(_:for:ifRefreshTokenIs:)`): a sign-in — here, in a
/// newer graph, or in another process — that writes a new grant while the
/// refresh is at the token endpoint must survive the refresh's late write.
/// Found by the UI-test harness (deadSession140): the unconditional write put
/// the dead family back and the account re-latched right after the user
/// signed in.
@Suite struct RefreshCompareAndSetTests {
    private static let accountID = "https://mail.test.invalid"

    private static func grant(_ name: String, expiresIn: TimeInterval = 3600) -> OAuthTokens {
        OAuthTokens(
            accessToken: "\(name)-access",
            refreshToken: "\(name)-refresh",
            expiresAt: Date().addingTimeInterval(expiresIn),
            scope: "mail:read offline_access"
        )
    }

    /// The race itself, on the production store. Fails if the refresh writes
    /// unconditionally: the store would hold the refresh's `access-1`, the
    /// caller would get it, and — since this provider minted it — the lineage
    /// would call the dead grant's death still current (the re-latch).
    @Test("a sign-in that lands while a refresh is in flight keeps its grant")
    func aSignInDuringARefreshWins() async throws {
        let keychain = SharedKeychain()
        try keychain.seed(Self.grant("old", expiresIn: -10), for: Self.accountID)
        let refresher = GatedRefresher.counting(released: false)
        let provider = AccountTokenProvider(accountID: Self.accountID, store: keychain.store, refresher: refresher)
        let deathOfOld = try #require(await provider.deathOfStoredGrant())

        let call = Task { try await provider.accessToken() }
        try await waitUntil("the refresh to reach the token endpoint", timeout: .seconds(10)) { await refresher.callCount == 1 }
        let signedIn = Self.grant("signin")
        try keychain.store.setTokens(signedIn, for: Self.accountID)
        await refresher.release()

        #expect(try await call.value == "signin-access")
        #expect(try keychain.store.tokens(for: Self.accountID) == signedIn, "the refresh overwrote the new grant")
        // Adopted, not minted: the re-auth is a recovery, not this provider's
        // own rotation of the dead grant.
        #expect(await deathOfOld.isCurrent() == false)
        // Still healthy afterwards: served from the store, nothing spent.
        #expect(try await provider.accessToken() == "signin-access")
        #expect(await refresher.callCount == 1)
    }

    /// Control: with nothing racing it, the rotation is persisted and recorded
    /// as this provider's own (P9b lineage). Fails if the compare-and-set
    /// refuses a store that still holds the spent grant, or if a persisted
    /// rotation stops being recorded in the lineage.
    @Test("an unraced refresh still persists and records its own rotation")
    func anUnracedRefreshPersists() async throws {
        let keychain = SharedKeychain()
        try keychain.seed(Self.grant("old", expiresIn: -10), for: Self.accountID)
        let refresher = GatedRefresher.counting()
        let provider = AccountTokenProvider(accountID: Self.accountID, store: keychain.store, refresher: refresher)
        let deathOfOld = try #require(await provider.deathOfStoredGrant())

        #expect(try await provider.accessToken() == "access-1")
        #expect(try keychain.store.tokens(for: Self.accountID)?.refreshToken == "refresh-1")
        #expect(await deathOfOld.isCurrent(), "its own rotation is the same session, not a recovery")
    }

    /// A refresh whose account was signed out (store emptied) while it was in
    /// flight must not resurrect tokens for it. Fails on an unconditional
    /// write.
    @Test("a refresh never writes tokens back for an account removed meanwhile")
    func aRefreshDoesNotResurrectARemovedAccount() async throws {
        let keychain = SharedKeychain()
        try keychain.seed(Self.grant("old", expiresIn: -10), for: Self.accountID)
        let refresher = GatedRefresher.counting(released: false)
        let provider = AccountTokenProvider(accountID: Self.accountID, store: keychain.store, refresher: refresher)

        let call = Task { try await provider.accessToken() }
        try await waitUntil("the refresh to reach the token endpoint", timeout: .seconds(10)) { await refresher.callCount == 1 }
        try keychain.store.setTokens(nil, for: Self.accountID)
        await refresher.release()

        _ = try await call.value
        #expect(try keychain.store.tokens(for: Self.accountID) == nil)
    }

    /// `invalid_grant` clears only while the store still holds the rejected
    /// token. The new grant lands AFTER the "was it superseded?" read (served a
    /// stale snapshot here) and before the clear. Fails on an unconditional
    /// clear: the sign-in's grant is deleted and the caller told to re-auth.
    @Test("an invalid_grant clear never deletes a grant written after its check")
    func anInvalidGrantClearSparesANewGrant() async throws {
        let keychain = SharedKeychain()
        let old = try keychain.seed(Self.grant("old", expiresIn: -10), for: Self.accountID)
        let view = StaleReadingStore(keychain.store)
        let refresher = GatedRefresher(released: false) { _ in
            throw OAuthError.server(error: "invalid_grant", description: "refresh token revoked")
        }
        let provider = AccountTokenProvider(accountID: Self.accountID, store: view, refresher: refresher)

        let call = Task { try await provider.accessToken() }
        try await waitUntil("the refresh to reach the token endpoint", timeout: .seconds(10)) { await refresher.callCount == 1 }
        let signedIn = Self.grant("signin")
        try keychain.store.setTokens(signedIn, for: Self.accountID)
        view.serveStale(old)
        await refresher.release()

        #expect(try await call.value == "signin-access")
        #expect(view.pendingStaleReads == 0, "the stale snapshot was never read: the race was not staged")
        #expect(try keychain.store.tokens(for: Self.accountID) == signedIn)
    }

    /// The Keychain store's compare-and-set is atomic with its plain writes: a
    /// sign-in's write issued between the compare's read and its write waits
    /// for the lock and lands AFTER it. Fails if `setTokens` bypasses the lock
    /// (the plain write completes while the compare is parked, then is
    /// overwritten by it).
    @Test("KeychainAccountStore's compare-and-set is atomic under its lock", .timeLimit(.minutes(1)))
    func keychainCompareAndSetIsAtomic() async throws {
        let secrets = ParkingSecretStore()
        let store = KeychainAccountStore(secrets: secrets)
        try store.setTokens(Self.grant("old"), for: Self.accountID)
        let fresh = Self.grant("fresh"), signedIn = Self.grant("signin")
        let accountID = Self.accountID

        secrets.parkNextRead(of: KeychainAccountStore.tokensKey(Self.accountID))
        // Plain threads, not the cooperative pool: both calls BLOCK (one parked,
        // one on the store's lock), and starving the pool stalls every other
        // suite running in parallel.
        let compareAndSet = BlockingCall { try store.setTokens(fresh, for: accountID, ifRefreshTokenIs: "old-refresh") }
        try await waitUntil("the compare to be parked after its read", timeout: .seconds(10)) { secrets.isParked }

        let plainWrite = BlockingCall { try store.setTokens(signedIn, for: accountID) }
        // Early exit for the broken case; the correct one waits it out.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(300))
        while ContinuousClock.now < deadline, !plainWrite.isDone {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!plainWrite.isDone, "a plain write landed inside the compare-and-set")

        secrets.release()
        try await waitUntil("both calls to finish", timeout: .seconds(10)) { compareAndSet.isDone && plainWrite.isDone }
        #expect(try compareAndSet.result.get())
        try plainWrite.result.get()
        #expect(try store.tokens(for: Self.accountID) == signedIn)
    }
}

/// Runs a synchronous, possibly blocking call on its own `Thread`.
private nonisolated final class BlockingCall<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Value, any Error>?

    init(_ body: @escaping @Sendable () throws -> Value) {
        let thread = Thread { [self] in
            let outcome = Result { try body() }
            lock.withLock { self.outcome = outcome }
        }
        thread.start()
    }

    var isDone: Bool { lock.withLock { outcome != nil } }
    /// Only once ``isDone``.
    var result: Result<Value, any Error> { lock.withLock { outcome! } }
}

/// A ``SecretStore`` whose next read of one key returns its value and then
/// PARKS the calling thread until released — the gap between a compare's read
/// and its write, held open.
private nonisolated final class ParkingSecretStore: SecretStore, @unchecked Sendable {
    private let base = InMemorySecretStore()
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var armedKey: String?
    private var parked = false

    var isParked: Bool { lock.withLock { parked } }

    func parkNextRead(of key: String) { lock.withLock { armedKey = key } }
    func release() { gate.signal() }

    func data(for key: String) throws -> Data? {
        let value = try base.data(for: key)
        let park = lock.withLock { () -> Bool in
            guard armedKey == key else { return false }
            armedKey = nil
            parked = true
            return true
        }
        if park {
            gate.wait()
            lock.withLock { parked = false }
        }
        return value
    }

    func set(_ data: Data, for key: String) throws { try base.set(data, for: key) }
    func removeValue(for key: String) throws { try base.removeValue(for: key) }
}
