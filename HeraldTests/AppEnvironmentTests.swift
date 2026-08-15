import Foundation
import HeraldKit
import Testing
@testable import Herald

@MainActor
@Suite struct AppEnvironmentLifecycleTests {
    private static func account(_ host: String) -> Account {
        Account(origin: URL(string: "https://\(host)")!, clientID: "cid", scopes: [])
    }

    /// Adding an account (or re-authenticating) built a new object graph on top of
    /// the old one: the previous `SyncEngine` kept polling the previous server
    /// forever and the previous `MailViewModel` kept consuming its events. Fails
    /// if the superseded engine still answers a refresh — the leak is invisible
    /// otherwise, because the new graph works fine either way.
    @Test func activatingASecondAccountStopsTheFirstGraph() async throws {
        let environment = AppEnvironment()
        let store = try MailStore.inMemory()
        let first = FakeMailAPIClient()
        let second = FakeMailAPIClient()

        await environment.install(account: Self.account("a.example.com"), api: first, store: store)
        let superseded = try #require(environment.mail)
        try await wait("the first account to poll once") { await first.mailboxRequestCount >= 1 }

        await environment.install(account: Self.account("b.example.com"), api: second, store: store)
        let leakedBaseline = await first.mailboxRequestCount

        // The superseded view-model still holds the superseded engine. Asking it to
        // refresh must do nothing, because that engine was stopped.
        await superseded.refresh()

        // Positive control on the live graph: it DOES poll again, which also gives
        // the superseded engine the same window in which to misbehave.
        let liveBaseline = await second.mailboxRequestCount
        await environment.mail?.refresh()
        try await wait("the live account to poll again") { await second.mailboxRequestCount > liveBaseline }

        #expect(
            await first.mailboxRequestCount == leakedBaseline,
            "The previous SyncEngine kept polling the previous server"
        )
    }
}
