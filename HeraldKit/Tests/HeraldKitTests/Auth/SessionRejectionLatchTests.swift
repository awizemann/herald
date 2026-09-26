import Foundation
import Testing
@testable import HeraldKit

/// Counts the provider's dead-session announcements, per account.
actor RejectionRecorder {
    private(set) var accountIDs: [Account.ID] = []
    func record(_ id: Account.ID) { accountIDs.append(id) }
    var count: Int { accountIDs.count }
}

/// The dead-session latch in ``AccountTokenProvider``, end to end: the real
/// middleware, the real provider, the real ``OAuthSession`` refresher, all
/// against a URLProtocol fake server.
///
/// The incident it pins (2026-09-26, live HQBase 1.4.0): the bound web session
/// died, every request got `401 invalid_token`, the refresh SUCCEEDED, and the
/// retry with the fresh token was refused again — repeated per request, six
/// rotations in ~65 s, and nothing but the sync poll ever escalated.
@Suite struct SessionRejectionLatchTests {
    private static let accountA = "https://mail.test.invalid"
    private static let accountB = "https://other.test.invalid"
    private static let invalidTokenChallenge = #"Bearer error="invalid_token""#
    private static let mailboxesPath = "/api/v1/mailboxes"

    private static func unauthorized() -> FakeResponse {
        .error(401, code: "INVALID_OAUTH_TOKEN", message: "dead", headers: ["WWW-Authenticate": invalidTokenChallenge])
    }

    private static func tokens(_ n: Int) -> OAuthTokens {
        OAuthTokens(
            accessToken: "access-\(n)",
            refreshToken: "refresh-\(n)",
            expiresAt: Date().addingTimeInterval(3600),
            scope: "mail:read offline_access"
        )
    }

    /// A server whose token endpoint always rotates successfully (`access-1`,
    /// `access-2`, …) — the 1.4.0 behaviour that made the storm possible — and
    /// whose API answers with `api`.
    private static func server(api: FakeResponse...) -> FakeServer {
        let server = FakeServer()
        server.route(
            "POST", AuthFixtures.tokenPath,
            .json(200, AuthFixtures.tokenJSON(access: "access-1", refresh: "refresh-1")),
            .json(200, AuthFixtures.tokenJSON(access: "access-2", refresh: "refresh-2")),
            .json(200, AuthFixtures.tokenJSON(access: "access-3", refresh: "refresh-3"))
        )
        server.route("GET", mailboxesPath, responses: api)
        return server
    }

    private struct Harness {
        let provider: AccountTokenProvider
        let client: HQBaseAPIClient
        let recorder: RejectionRecorder
    }

    private static func harness(
        server: FakeServer,
        store: any AccountStore,
        accountID: Account.ID = accountA
    ) async -> Harness {
        let session = server.makeSession()
        let provider = AccountTokenProvider(
            accountID: accountID,
            store: store,
            refresher: OAuthSession(configuration: AuthFixtures.configuration, clientID: "cid", session: session),
            refreshLeeway: 60
        )
        let recorder = RejectionRecorder()
        await provider.setSessionRejectedHandler { await recorder.record($0) }
        let client = HQBaseAPIClient(origin: FakeServer.origin, tokens: provider, session: session)
        return Harness(provider: provider, client: client, recorder: recorder)
    }

    private static func store(seeding tokens: OAuthTokens, for accountID: Account.ID = accountA) throws -> RecordingAccountStore {
        let store = RecordingAccountStore()
        try store.setTokens(tokens, for: accountID)
        return store
    }

    // MARK: - The storm

    /// Fails on the pre-fix code three ways: every call after the first spends
    /// another refresh (token requests 2, 3, 4), no announcement is ever made,
    /// and each later call still sends a doomed API request.
    @Test("refresh-OK-then-401 latches the grant: one announcement, then zero token-endpoint requests")
    func refreshedTokenRejectedLatchesTheGrant() async throws {
        let server = Self.server(api: Self.unauthorized())
        let store = try Self.store(seeding: Self.tokens(0))
        let h = await Self.harness(server: server, store: store)

        await #expect(throws: MailAPIError.unauthorized) { _ = try await h.client.listMailboxes() }
        #expect(server.requests(path: AuthFixtures.tokenPath).count == 1)
        #expect(server.requests(path: Self.mailboxesPath).map(\.authorization) == ["Bearer access-0", "Bearer access-1"])
        #expect(await h.recorder.accountIDs == [Self.accountA])

        for _ in 0..<3 {
            await #expect(throws: MailAPIError.unauthorized) { _ = try await h.client.listMailboxes() }
        }
        await #expect(throws: OAuthError.reauthenticationRequired) { _ = try await h.provider.accessToken() }
        await #expect(throws: OAuthError.reauthenticationRequired) {
            _ = try await h.provider.refreshAccessToken(failedToken: "access-1")
        }

        #expect(server.requests(path: AuthFixtures.tokenPath).count == 1, "the dead grant was spent again")
        #expect(server.requests(path: Self.mailboxesPath).count == 2, "a latched account still hit the API")
        #expect(await h.recorder.count == 1, "the same death was announced more than once")
        // Unlike invalid_grant, the item stays: re-auth overwrites it, and on a
        // 1.4.2 server the refresh token may be perfectly good.
        #expect(try store.tokens(for: Self.accountA)?.refreshToken == "refresh-1")
    }

    /// The incident shape: several requests in flight when the session dies, each
    /// reporting its refused retry. The handler is held open (it hops to the main
    /// actor in the app), so every other report lands on the re-entrant actor
    /// WHILE the first announcement is suspended. Fails if the latch is written
    /// after awaiting the handler instead of before it — N announcements.
    @Test("concurrent reports of one death announce it exactly once", .timeLimit(.minutes(1)))
    func concurrentReportsAnnounceOnce() async throws {
        let store = try Self.store(seeding: Self.tokens(1))
        let provider = AccountTokenProvider(
            accountID: Self.accountA, store: store, refresher: GatedRefresher.counting(), refreshLeeway: 60
        )
        let recorder = RejectionRecorder()
        let gate = Gate()
        // Only the FIRST announcement parks. A wrongly repeated one records and
        // returns, so the bug shows up as a count, not as a hung test.
        await provider.setSessionRejectedHandler { id in
            await recorder.record(id)
            if await recorder.count == 1 { await gate.wait() }
        }

        let first = Task { await provider.sessionRejected(token: "access-1") }
        try await waitUntil("the first announcement is parked in the handler") { await gate.isWaiting }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { await provider.sessionRejected(token: "access-1") }
            }
        }
        await gate.release()
        await first.value

        #expect(await recorder.count == 1)
    }

    // MARK: - Must not latch

    /// The stale-401 path: this request's token was already replaced by the time
    /// its 401 arrived, the provider re-serves the replacement WITHOUT a refresh,
    /// and the retry succeeds. Fails if a 401 alone (rather than a 401 for the
    /// token just handed out) latches — that would sign the user out on every
    /// ordinary overlap of requests around an expiry.
    @Test("a stale 401 whose retry succeeds neither refreshes, latches, nor announces")
    func staleUnauthorizedRecoveryDoesNotLatch() async throws {
        let server = Self.server(api: Self.unauthorized(), .json(200, Fixtures.mailboxesJSON))
        let keychain = SharedKeychain()
        try keychain.seed(Self.tokens(5), for: Self.accountA)
        // This request read the item just before another request replaced it.
        let store = StaleReadingStore(keychain.store)
        store.serveStale(Self.tokens(4))
        let h = await Self.harness(server: server, store: store)

        #expect(try await h.client.listMailboxes().count == 2)
        #expect(server.requests(path: Self.mailboxesPath).map(\.authorization) == ["Bearer access-4", "Bearer access-5"])
        #expect(server.requests(path: AuthFixtures.tokenPath).isEmpty)
        #expect(await h.recorder.count == 0)
        #expect(try await h.provider.accessToken() == "access-5")
    }

    /// The same stale path, but the re-served replacement is refused too. That
    /// token was handed out for the retry just as a fresh one would be, so this
    /// is a dead grant. Fails if only freshly MINTED tokens count — in the
    /// incident most of the six requests took exactly this path.
    @Test("a re-served replacement that is refused latches the grant without any refresh")
    func refusedReplacementLatches() async throws {
        let server = Self.server(api: Self.unauthorized())
        let keychain = SharedKeychain()
        try keychain.seed(Self.tokens(5), for: Self.accountA)
        let store = StaleReadingStore(keychain.store)
        store.serveStale(Self.tokens(4))
        let h = await Self.harness(server: server, store: store)

        await #expect(throws: MailAPIError.unauthorized) { _ = try await h.client.listMailboxes() }
        await #expect(throws: MailAPIError.unauthorized) { _ = try await h.client.listMailboxes() }

        #expect(server.requests(path: AuthFixtures.tokenPath).isEmpty)
        #expect(server.requests(path: Self.mailboxesPath).count == 2)
        #expect(await h.recorder.count == 1)
    }

    /// A rejection report for a token the store has already moved past (another
    /// request or process refreshed after this one's retry went out) is about a
    /// superseded token. Fails if the provider latches whatever grant happens to
    /// be stored now — that would condemn a grant nobody has tried yet.
    @Test("a rejection report for a superseded token latches nothing")
    func supersededRejectionIsIgnored() async throws {
        let store = try Self.store(seeding: Self.tokens(2))
        let refresher = GatedRefresher.counting()
        let provider = AccountTokenProvider(accountID: Self.accountA, store: store, refresher: refresher, refreshLeeway: 60)
        let recorder = RejectionRecorder()
        await provider.setSessionRejectedHandler { await recorder.record($0) }

        await provider.sessionRejected(token: "access-1")

        #expect(try await provider.accessToken() == "access-2")
        #expect(await recorder.count == 0)
    }

    // MARK: - The latch belongs to the grant

    /// After re-auth the store holds a new grant — written by the app's new graph
    /// (or another process), never by this provider. A composer still holding the
    /// superseded graph keeps using THIS provider. Fails if the latch is tied to
    /// the provider's lifetime (the composer can never send again) rather than
    /// to the grant. Also pins "once per dead grant": the NEW grant dying is a
    /// new death and is announced again.
    @Test("a new grant written to the store clears the latch and is served; its own death is announced again")
    func newGrantClearsTheLatch() async throws {
        let server = Self.server(api: Self.unauthorized(), Self.unauthorized(), .json(200, Fixtures.mailboxesJSON), Self.unauthorized())
        let store = try Self.store(seeding: Self.tokens(0))
        let h = await Self.harness(server: server, store: store)

        await #expect(throws: MailAPIError.unauthorized) { _ = try await h.client.listMailboxes() }
        #expect(await h.recorder.count == 1)

        // Re-auth lands elsewhere.
        try store.setTokens(Self.tokens(9), for: Self.accountA)

        #expect(try await h.client.listMailboxes().count == 2)
        #expect(server.requests(path: Self.mailboxesPath).last?.authorization == "Bearer access-9")
        #expect(server.requests(path: AuthFixtures.tokenPath).count == 1, "the new grant was refreshed for no reason")

        // The new grant dies too: 401 → refresh (spends refresh-9) → 401.
        await #expect(throws: MailAPIError.unauthorized) { _ = try await h.client.listMailboxes() }
        #expect(await h.recorder.count == 2)
        #expect(server.requests(path: AuthFixtures.tokenPath).count == 2)
    }

    // MARK: - Per-account isolation

    /// Multi-account is next, and one provider per account shares ONE store (the
    /// Keychain). Fails if the latch or the handler is shared state — a single
    /// dead account would sign every account out.
    @Test("one account's dead session never latches or announces another's")
    func accountsAreIsolated() async throws {
        let keychain = SharedKeychain()
        try keychain.seed(Self.tokens(0), for: Self.accountA)
        try keychain.seed(OAuthTokens(
            accessToken: "b-access",
            refreshToken: "b-refresh",
            expiresAt: Date().addingTimeInterval(3600),
            scope: "mail:read offline_access"
        ), for: Self.accountB)
        let serverA = Self.server(api: Self.unauthorized())
        let serverB = Self.server(api: .json(200, Fixtures.mailboxesJSON))
        let a = await Self.harness(server: serverA, store: keychain.store, accountID: Self.accountA)
        let b = await Self.harness(server: serverB, store: keychain.store, accountID: Self.accountB)

        await #expect(throws: MailAPIError.unauthorized) { _ = try await a.client.listMailboxes() }
        #expect(await a.recorder.accountIDs == [Self.accountA])

        #expect(try await b.client.listMailboxes().count == 2)
        #expect(try await b.provider.accessToken() == "b-access")
        #expect(await b.recorder.count == 0)
        #expect(serverB.requests(path: AuthFixtures.tokenPath).isEmpty)
        // And A stays latched after B's traffic.
        await #expect(throws: OAuthError.reauthenticationRequired) { _ = try await a.provider.accessToken() }
    }

    // MARK: - The other deaths announce through the same handler (P2)

    /// `invalid_grant` is the OTHER death — the refresh itself refused — and keeps
    /// its own handling: the dead item is cleared and the call surfaces as
    /// `.unauthorized`. Since P2 it ALSO announces, so the app has one signal for
    /// every dead session. Fails if the latch work leaks into it (the item kept,
    /// or a second refresh attempted), if it stays silent (a send or autosave
    /// that hit it would leave no banner until the next poll), or if the empty
    /// store the clear leaves behind is announced as a second death.
    @Test("invalid_grant clears the item, never latches, and announces exactly once")
    func invalidGrantAnnouncesOnce() async throws {
        let server = FakeServer()
        server.route("POST", AuthFixtures.tokenPath, .json(400, #"{"error":"invalid_grant","error_description":"revoked"}"#))
        server.route("GET", Self.mailboxesPath, Self.unauthorized())
        let store = try Self.store(seeding: Self.tokens(0))
        let h = await Self.harness(server: server, store: store)

        await #expect(throws: MailAPIError.unauthorized) { _ = try await h.client.listMailboxes() }
        #expect(server.requests(path: AuthFixtures.tokenPath).count == 1)
        #expect(server.requests(path: Self.mailboxesPath).count == 1)
        #expect(try store.tokens(for: Self.accountA) == nil)
        #expect(await h.recorder.accountIDs == [Self.accountA])

        // Every later request finds the item gone (missingRefreshToken) — the
        // same death, not a new one.
        for _ in 0..<3 {
            await #expect(throws: MailAPIError.unauthorized) { _ = try await h.client.listMailboxes() }
        }
        await #expect(throws: OAuthError.missingRefreshToken) { _ = try await h.provider.accessToken() }
        #expect(await h.recorder.count == 1, "the aftermath of one invalid_grant was announced again")
        #expect(server.requests(path: AuthFixtures.tokenPath).count == 1)
    }

    /// Several requests in flight when the refresh token dies all JOIN the one
    /// refresh. Fails if every joiner announces, rather than only the caller
    /// that started the refresh.
    @Test("concurrent requests that share one invalid_grant refresh announce once", .timeLimit(.minutes(1)))
    func concurrentInvalidGrantAnnouncesOnce() async throws {
        let store = try Self.store(seeding: OAuthTokens(
            accessToken: "expired", refreshToken: "refresh-0",
            expiresAt: Date().addingTimeInterval(-10), scope: "mail:read offline_access"
        ))
        let refresher = GatedRefresher(released: false) { _ in
            throw OAuthError.server(error: "invalid_grant", description: "revoked")
        }
        let provider = AccountTokenProvider(accountID: Self.accountA, store: store, refresher: refresher, refreshLeeway: 60)
        let recorder = RejectionRecorder()
        await provider.setSessionRejectedHandler { await recorder.record($0) }

        let callers = (0..<5).map { _ in Task { try await provider.accessToken() } }
        try await waitUntil("the refresh is in flight") { await refresher.callCount == 1 }
        await refresher.release()
        for caller in callers {
            await #expect(throws: OAuthError.reauthenticationRequired) { _ = try await caller.value }
        }

        #expect(await refresher.callCount == 1)
        #expect(await recorder.count == 1)
    }

    /// A grant with no refresh token (the server did not grant `offline_access`)
    /// dies at its first expiry. Fails if that stays silent, or if each request
    /// after it announces again.
    @Test("a grant with no refresh token announces its death once")
    func missingRefreshTokenAnnouncesOnce() async throws {
        let store = try Self.store(seeding: OAuthTokens(
            accessToken: "no-offline", refreshToken: nil,
            expiresAt: Date().addingTimeInterval(-10), scope: "mail:read"
        ))
        let refresher = GatedRefresher.counting()
        let provider = AccountTokenProvider(accountID: Self.accountA, store: store, refresher: refresher, refreshLeeway: 60)
        let recorder = RejectionRecorder()
        await provider.setSessionRejectedHandler { await recorder.record($0) }

        for _ in 0..<3 {
            await #expect(throws: OAuthError.missingRefreshToken) { _ = try await provider.accessToken() }
        }
        await #expect(throws: OAuthError.missingRefreshToken) {
            _ = try await provider.refreshAccessToken(failedToken: "no-offline")
        }

        #expect(await recorder.accountIDs == [Self.accountA])
        #expect(await refresher.callCount == 0)
    }

    /// "Once per grant", not "once per provider": after a re-auth writes a new
    /// grant, that grant's own `invalid_grant` is a new death. Fails if the
    /// announced state is never forgotten — the second expiry would then raise
    /// no banner and no automatic attempt.
    @Test("a re-auth's new grant dying by invalid_grant is announced again")
    func newGrantInvalidGrantAnnouncesAgain() async throws {
        let server = FakeServer()
        server.route("POST", AuthFixtures.tokenPath, .json(400, #"{"error":"invalid_grant","error_description":"revoked"}"#))
        server.route("GET", Self.mailboxesPath, Self.unauthorized())
        let store = try Self.store(seeding: Self.tokens(0))
        let h = await Self.harness(server: server, store: store)

        await #expect(throws: MailAPIError.unauthorized) { _ = try await h.client.listMailboxes() }
        #expect(await h.recorder.count == 1)

        try store.setTokens(Self.tokens(9), for: Self.accountA)
        await #expect(throws: MailAPIError.unauthorized) { _ = try await h.client.listMailboxes() }

        #expect(await h.recorder.count == 2)
        #expect(server.requests(path: AuthFixtures.tokenPath).count == 2)
    }

    /// The item can also be emptied by SOMEONE ELSE (another process's
    /// `invalid_grant` on a grant this provider only ever read). Once this
    /// provider has seen a live grant since its last announcement, that empty
    /// store is a new death. Fails if the announced state is only ever compared
    /// by key — the earlier death would then silence this one.
    @Test("an empty store after a re-auth this provider has seen is announced as a new death")
    func emptiedAfterReauthAnnouncesAgain() async throws {
        let server = FakeServer()
        server.route("POST", AuthFixtures.tokenPath, .json(400, #"{"error":"invalid_grant","error_description":"revoked"}"#))
        server.route("GET", Self.mailboxesPath, Self.unauthorized())
        let store = try Self.store(seeding: Self.tokens(0))
        let h = await Self.harness(server: server, store: store)

        await #expect(throws: MailAPIError.unauthorized) { _ = try await h.client.listMailboxes() }
        #expect(await h.recorder.count == 1)

        try store.setTokens(Self.tokens(9), for: Self.accountA)
        #expect(try await h.provider.accessToken() == "access-9")
        // Another process found the new grant dead and cleared it.
        try store.setTokens(nil, for: Self.accountA)
        await #expect(throws: OAuthError.missingRefreshToken) { _ = try await h.provider.accessToken() }

        #expect(await h.recorder.count == 2)
        #expect(server.requests(path: AuthFixtures.tokenPath).count == 1)
    }

    /// The surface the incident actually hurt: a SEND, not the sync loop. Every
    /// REST call shares the one middleware, so a send's refused retry reaches
    /// the handler exactly like a poll's — and the composer sees
    /// `OutboxError.api(.unauthorized)`, which is what the app keys its
    /// re-auth handling on. Fails if the outbox path swallows the report.
    @Test("a send refused after a refresh announces the death and surfaces as OutboxError.api(.unauthorized)")
    func sendRefusedAfterRefreshAnnounces() async throws {
        let server = Self.server()
        server.route("POST", "/api/v1/send", Self.unauthorized())
        let store = try Self.store(seeding: Self.tokens(0))
        let h = await Self.harness(server: server, store: store)
        let outbox = OutboxService(api: h.client)
        let draft = ComposeDraft(mode: .new(mailboxID: nil), fromAddress: "support@example.com", to: ["a@b.test"], subject: "Hi", body: "Hello")

        await #expect(throws: OutboxError.api(.unauthorized)) { _ = try await outbox.send(draft) }
        #expect(await h.recorder.accountIDs == [Self.accountA])

        // The next send fails fast: no refresh, no request.
        await #expect(throws: OutboxError.api(.unauthorized)) { _ = try await outbox.send(draft) }
        #expect(server.requests(path: "/api/v1/send").count == 2)
        #expect(server.requests(path: AuthFixtures.tokenPath).count == 1)
        #expect(await h.recorder.count == 1)
    }

    // MARK: - The wake socket

    /// The socket's "unauthorized after a refresh" path, wired to the REAL
    /// provider. Fails if the socket escalates only to its own owner: REST would
    /// then keep refreshing the dead grant, and a restarted socket (every app
    /// activation) would spend another rotation before escalating again.
    @Test("the socket's refused retry latches the provider; a restart escalates with no refresh and no upgrade", .timeLimit(.minutes(1)))
    func socketReportsToTheProvider() async throws {
        let store = try Self.store(seeding: Self.tokens(0))
        let refresher = GatedRefresher.counting()
        let provider = AccountTokenProvider(accountID: Self.accountA, store: store, refresher: refresher, refreshLeeway: 60)
        let rejections = RejectionRecorder()
        await provider.setSessionRejectedHandler { await rejections.record($0) }
        let recorder = SignalRecorder()
        let channels = FakeMailEventChannels([.rejected(.unauthorized), .rejected(.unauthorized)])
        let socket = MailEventSocket(
            channels: channels,
            tokens: provider,
            sleep: { _ in },
            watchdogSleep: MailEventSocketTests.neverReturns,
            jitter: { 0 },
            reauthenticationRequired: { await recorder.recordReauth() },
            signal: { await recorder.record($0) }
        )

        await socket.start()
        try await waitUntil("the first escalation") { await recorder.reauthCount == 1 }
        #expect(await channels.tokens == ["access-0", "access-1"])
        #expect(await rejections.accountIDs == [Self.accountA])

        await socket.stop()
        await socket.start()
        try await waitUntil("the second escalation") { await recorder.reauthCount == 2 }
        await socket.stop()

        #expect(await refresher.callCount == 1, "the restarted socket spent the dead grant again")
        #expect(await channels.openCount == 2, "the restarted socket tried an upgrade with a dead grant")
        #expect(await rejections.count == 1)
    }
}
