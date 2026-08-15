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

    /// The compose window's `.task(id:)` re-runs whenever SwiftUI rebuilds the
    /// scene root, and the old code CONSUMED the resolved context on the way
    /// through: the second run built nothing, so a half-written message turned
    /// into "this draft is no longer available". Fails if the same request id
    /// stops resolving to the same composer, or if a closed composer is
    /// resurrected instead of released.
    @Test func theSameComposeRequestAlwaysResolvesToTheSameViewModel() async throws {
        let environment = AppEnvironment()
        let store = try MailStore.inMemory()
        await environment.install(
            account: Self.account("a.example.com"),
            api: FakeMailAPIClient(),
            store: store
        )

        let id = try #require(await environment.prepareCompose(ComposeRequest(kind: .new)))
        let first = try #require(environment.makeComposeViewModel(id: id))
        first.bodyText = "Half-written"
        let second = try #require(environment.makeComposeViewModel(id: id))

        #expect(first === second, "Rebuilding the compose window discarded the draft")
        #expect(second.bodyText == "Half-written")

        // Releasing an OPEN composer must not drop it either.
        environment.releaseComposeViewModel(id: id)
        #expect(environment.makeComposeViewModel(id: id) === first)

        // Once it really is closed the window shows "no longer available" rather
        // than a resurrected copy of a sent message.
        first.close()
        environment.releaseComposeViewModel(id: id)
        #expect(environment.makeComposeViewModel(id: id) == nil)
    }
}
