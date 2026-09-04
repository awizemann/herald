import Foundation
import Testing
@testable import HeraldKit

/// What the wake socket does to the poll loop.
///
/// The rule these tests pin down: the socket STRETCHES the poll, it never
/// replaces it. Upstream documents the frames as wake-only, with no replay of
/// anything missed, so a client that stopped polling would diverge silently the
/// first time a frame was dropped.
@Suite("Poll stretching under the wake socket")
struct PollStretchTests {
    private static let account = SyncFixtures.account

    @Test("A connected socket stretches the interval; losing it restores the cadence")
    func stretchFollowsTheSocket() async throws {
        let engine = SyncEngine(api: FakeMailAPIClient(), store: try MailStore.inMemory())

        #expect(await engine.currentPollInterval == .seconds(15), "active cadence, no socket")
        await engine.setWakeSocketConnected(true)
        #expect(await engine.currentPollInterval == .seconds(120), "stretched, but still polling")
        await engine.setCadence(.idle)
        #expect(await engine.currentPollInterval == .seconds(300))
        await engine.setWakeSocketConnected(false)
        #expect(await engine.currentPollInterval == .seconds(60), "the cadence is restored at once")
    }

    /// Fails if a dropped socket leaves the loop asleep for the rest of a
    /// stretched wait: the socket is what was making changes visible, and its
    /// loss is exactly the moment the poll has to take over.
    @Test("Losing the socket wakes the loop instead of waiting out the stretch")
    func losingTheSocketWakesTheLoop() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        let store = try MailStore.inMemory()
        let engine = SyncEngine(api: api, store: store)
        await engine.setWakeSocketConnected(true)

        await engine.start(accountID: Self.account)
        try await waitUntil("the first pass ran and the loop parked") {
            await engine.isParkedOnCadenceWait
        }
        let before = await api.callCount { if case .listMailboxes = $0 { return true } else { return false } }

        await engine.setWakeSocketConnected(false)
        try await waitUntil("the loop woke and ran a pass") {
            await api.callCount { if case .listMailboxes = $0 { return true } else { return false } } > before
        }
        await engine.stopAndWait()
    }

    /// Fails if a healthy socket suppresses backoff. A failing server is a
    /// failing server whatever the socket is doing, and a stretched interval must
    /// not shorten the recovery wait either.
    @Test("Backoff after a failed pass still wins over the stretch")
    func backoffOutranksTheStretch() async throws {
        let api = FakeMailAPIClient()
        await api.setListFailure(.server(code: "http_500", message: "boom"))
        let store = try MailStore.inMemory()
        let engine = SyncEngine(api: api, store: store)
        await engine.setWakeSocketConnected(true)

        await engine.start(accountID: Self.account)
        try await waitUntil("the failing pass was counted") { await engine.consecutiveFailureCount >= 1 }
        // 2 × the ACTIVE cadence, not a fraction of the stretched one.
        #expect(await engine.currentPollInterval == .seconds(30))
        await engine.stopAndWait()
    }
}
