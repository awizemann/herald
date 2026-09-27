import Foundation
import Testing
@testable import HeraldKit

/// P9b's two HeraldKit seams: a grant marker for a death the provider did not
/// detect itself (the app's heal probe, audit N2/W10), and telling a DAMAGED
/// account list apart from an empty one (so the launch can explain it).
@Suite struct SessionRecoveryP9bKitTests {
    private static let accountID = "https://mail.test.invalid"

    private static func grant(_ n: Int) -> OAuthTokens {
        OAuthTokens(accessToken: "access-\(n)", refreshToken: "refresh-\(n)", expiresAt: Date().addingTimeInterval(3600))
    }

    /// The marker is "current" while the store holds the same grant — however
    /// often it is asked — and stops being current once a DIFFERENT grant is
    /// stored. Fails if the marker latches or announces anything (the provider
    /// must still serve the grant), or never notices the change.
    @Test func aStoredGrantMarkerTracksTheStore() async throws {
        let store = RecordingAccountStore()
        try store.setTokens(Self.grant(0), for: Self.accountID)
        let provider = AccountTokenProvider(
            accountID: Self.accountID, store: store, refresher: RotatingRefresher(), refreshLeeway: 60
        )
        let marker = try #require(await provider.deathOfStoredGrant())
        #expect(await marker.isCurrent())
        #expect(await marker.isCurrent())
        // Nothing was latched: the grant is still served.
        #expect(try await provider.accessToken() == "access-0")

        try store.setTokens(Self.grant(1), for: Self.accountID)
        #expect(await marker.isCurrent() == false, "a renewed grant still looked dead")
    }

    /// HQBase rotates the refresh token on every use, so after the provider's
    /// OWN refresh the store holds "a different grant" — but it is the same
    /// dead session, one rotation on (a bare 401 is never latched and keeps
    /// refreshing). Fails if that counts as a recovery (the app would
    /// re-install on every activation), or if a grant another process stored
    /// after it — or adopted by this provider — does not.
    @Test func theProvidersOwnRotationIsNotARecovery() async throws {
        let store = RecordingAccountStore()
        try store.setTokens(Self.grant(0), for: Self.accountID)
        let provider = AccountTokenProvider(
            accountID: Self.accountID, store: store, refresher: RotatingRefresher(), refreshLeeway: 60
        )
        let marker = try #require(await provider.deathOfStoredGrant())

        // Two refreshes by this provider: refresh-0 → refresh-1 → refresh-2.
        _ = try await provider.refreshAccessToken(failedToken: "access-0")
        _ = try await provider.refreshAccessToken(failedToken: "access-1")
        #expect(try store.tokens(for: Self.accountID)?.refreshToken == "refresh-2")
        #expect(await marker.isCurrent(), "the provider's own refresh looked like another process signing in")

        // Another process signs in: a grant this provider never minted.
        try store.setTokens(Self.grant(9), for: Self.accountID)
        #expect(await marker.isCurrent() == false)

        // Adopting it (a read that finds it) does not make it "ours".
        _ = try await provider.accessToken()
        #expect(await marker.isCurrent() == false, "an adopted grant was recorded as this provider's rotation")
    }

    /// An unreadable store gives NO marker: one recorded as "no grant" would
    /// make any grant read later look like a recovery.
    @Test func anUnreadableStoreGivesNoMarker() async throws {
        let base = RecordingAccountStore()
        try base.setTokens(Self.grant(0), for: Self.accountID)
        let provider = AccountTokenProvider(
            accountID: Self.accountID, store: FailingReadStore(base, failReadsAfter: 0),
            refresher: RotatingRefresher(), refreshLeeway: 60
        )
        #expect(await provider.deathOfStoredGrant() == nil)
    }

    /// Fails if a damaged (non-JSON) index is indistinguishable from an empty
    /// one — the launch could not explain where the accounts went — or if a
    /// missing, empty or healthy index is reported damaged.
    @Test func aDamagedIndexIsReportedAsDamaged() throws {
        let secrets = InMemorySecretStore()
        let store = KeychainAccountStore(secrets: secrets)
        #expect(try store.accountIndexIsDamaged() == false, "a missing index is not damaged")

        try secrets.set(Data(), for: "accounts.index")
        #expect(try store.accountIndexIsDamaged() == false, "an empty item is a missing index")

        try secrets.set(Data("not json".utf8), for: "accounts.index")
        #expect(try store.accountIndexIsDamaged())
        #expect(try store.accounts().isEmpty)

        // The next write sets it aside and starts a healthy list.
        try store.add(Account(origin: URL(string: Self.accountID)!, clientID: "cid", scopes: []))
        #expect(try store.accountIndexIsDamaged() == false)
    }

    /// Through the coordinator, off the main actor.
    @Test func theCoordinatorReportsADamagedIndex() async throws {
        let secrets = InMemorySecretStore()
        try secrets.set(Data([0xFF, 0x00]), for: "accounts.index")
        let coordinator = await AuthCoordinator(store: KeychainAccountStore(secrets: secrets))
        #expect(await coordinator.accountIndexIsDamaged())
        #expect(try await coordinator.loadAccounts().isEmpty)
    }
}
