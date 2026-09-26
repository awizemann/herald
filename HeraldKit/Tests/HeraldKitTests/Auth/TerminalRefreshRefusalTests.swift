import Foundation
import Testing
@testable import HeraldKit

/// Audit W3: token-endpoint refusals other than `invalid_grant`.
///
/// Before the fix, `invalid_client`, `unauthorized_client`, a bare 401 and
/// `invalid_scope`/`invalid_target` all came back as `OAuthError.server` — not
/// retryable, not latched, never announced. The app mapped them to "Sync
/// problem" with a Retry that repeated the doomed refresh, and every sync pass,
/// socket reconnect and user action POSTed the token endpoint again. The stored
/// `client.<origin>` also survived, so Sign In reused a client the server no
/// longer had and the browser landed on the server's error page.
@Suite nonisolated struct TerminalRefreshRefusalTests {
    private static let origin = AuthFixtures.origin
    private static let accountID = "https://mail.test.invalid"
    private static let otherOrigin = URL(string: "https://other.test.invalid")!
    private static let mailboxesPath = "/api/v1/mailboxes"
    private static let invalidTokenChallenge = #"Bearer error="invalid_token""#

    private static func unauthorized() -> FakeResponse {
        .error(401, code: "INVALID_OAUTH_TOKEN", message: "dead", headers: ["WWW-Authenticate": invalidTokenChallenge])
    }

    private static func tokens(_ n: Int, expiresIn: TimeInterval = 3600) -> OAuthTokens {
        OAuthTokens(
            accessToken: "access-\(n)",
            refreshToken: "refresh-\(n)",
            expiresAt: Date().addingTimeInterval(expiresIn),
            scope: "mail:read offline_access"
        )
    }

    /// One way the token endpoint can refuse a refresh, and whether it means the
    /// CLIENT is dead (the registration must be forgotten).
    struct Refusal: Sendable, CustomTestStringConvertible {
        let name: String
        let response: FakeResponse
        let rejectsClient: Bool
        var testDescription: String { name }
    }

    static let refusals: [Refusal] = [
        // better-auth's answer for a public client it no longer has.
        Refusal(
            name: "400 invalid_client",
            response: .json(400, #"{"error":"invalid_client","error_description":"missing client"}"#),
            rejectsClient: true
        ),
        Refusal(
            name: "401 invalid_client",
            response: .json(401, #"{"error":"invalid_client"}"#),
            rejectsClient: true
        ),
        Refusal(
            name: "400 unauthorized_client",
            response: .json(400, #"{"error":"unauthorized_client"}"#),
            rejectsClient: true
        ),
        // A gateway's 401: no OAuth body. Dead session, but the registration
        // is NOT the server's to condemn here.
        Refusal(
            name: "bare 401",
            response: FakeResponse(status: 401, headers: ["Content-Type": "text/html"], body: Data("<html>401</html>".utf8)),
            rejectsClient: false
        ),
        Refusal(
            name: "400 invalid_scope",
            response: .json(400, #"{"error":"invalid_scope"}"#),
            rejectsClient: false
        ),
        Refusal(
            name: "400 invalid_target",
            response: .json(400, #"{"error":"invalid_target"}"#),
            rejectsClient: false
        ),
    ]

    private struct Harness {
        let server: FakeServer
        let store: RecordingAccountStore
        let provider: AccountTokenProvider
        let client: HQBaseAPIClient
        let recorder: RejectionRecorder
    }

    /// Real middleware, real provider, real `OAuthSession` refresher over the
    /// fake server. The account's registration is `cid`; another origin holds
    /// the SAME id, to prove only this origin's item is touched.
    private static func harness(token: FakeResponse..., registered: String = "cid") async throws -> Harness {
        let server = FakeServer()
        server.route("POST", AuthFixtures.tokenPath, responses: token)
        server.route("GET", mailboxesPath, unauthorized())
        let store = RecordingAccountStore(clientIDs: [
            origin.absoluteString: registered,
            otherOrigin.absoluteString: "cid",
        ])
        try store.setTokens(tokens(0), for: accountID)
        let session = server.makeSession()
        let provider = AccountTokenProvider(
            accountID: accountID,
            store: store,
            refresher: OAuthSession(configuration: AuthFixtures.configuration, clientID: "cid", session: session),
            refreshLeeway: 60,
            origin: origin,
            clientID: "cid"
        )
        let recorder = RejectionRecorder()
        await provider.setSessionRejectedHandler { await recorder.record($0.accountID) }
        let client = HQBaseAPIClient(origin: FakeServer.origin, tokens: provider, session: session)
        return Harness(server: server, store: store, provider: provider, client: client, recorder: recorder)
    }

    // MARK: - Refresh leg

    /// Fails on the pre-fix code: the first call surfaces a `.transport`-ish
    /// error (not `.unauthorized`), nothing is announced, and every later call
    /// POSTs the token endpoint again. Also fails if a client refusal leaves the
    /// registration in place, if a non-client refusal (a gateway 401) discards
    /// it, or if another origin's registration is touched.
    @Test("a terminal refresh refusal is one announcement, then no token-endpoint requests", arguments: refusals)
    func terminalRefusalLatches(_ refusal: Refusal) async throws {
        let h = try await Self.harness(token: refusal.response)

        await #expect(throws: MailAPIError.unauthorized) { _ = try await h.client.listMailboxes() }
        #expect(h.server.requests(path: AuthFixtures.tokenPath).count == 1)
        #expect(await h.recorder.accountIDs == [Self.accountID])

        for _ in 0..<3 {
            await #expect(throws: MailAPIError.unauthorized) { _ = try await h.client.listMailboxes() }
        }
        await #expect(throws: OAuthError.reauthenticationRequired) { _ = try await h.provider.accessToken() }
        await #expect(throws: OAuthError.reauthenticationRequired) {
            _ = try await h.provider.refreshAccessToken(failedToken: "access-0")
        }

        #expect(h.server.requests(path: AuthFixtures.tokenPath).count == 1, "the refused grant was spent again")
        #expect(h.server.requests(path: Self.mailboxesPath).count == 1, "a latched account still hit the API")
        #expect(await h.recorder.count == 1, "the same death was announced more than once")
        // Latched in memory, never cleared: a relaunch may try it again, and a
        // clear could delete a grant another process just wrote.
        #expect(try h.store.tokens(for: Self.accountID)?.refreshToken == "refresh-0")
        let registration = try h.store.clientID(for: Self.origin)
        #expect(registration == (refusal.rejectsClient ? nil : "cid"))
        #expect(try h.store.clientID(for: Self.otherOrigin) == "cid", "another origin's registration was touched")
    }

    /// Compare-and-delete: the refused id is no longer the stored one (another
    /// process or a sign-in here already registered anew), so it must survive.
    @Test("a client refusal never forgets a registration that has since changed")
    func newerRegistrationSurvives() async throws {
        let h = try await Self.harness(
            token: .json(400, #"{"error":"invalid_client"}"#),
            registered: "cid_new"
        )

        await #expect(throws: MailAPIError.unauthorized) { _ = try await h.client.listMailboxes() }

        #expect(try h.store.clientID(for: Self.origin) == "cid_new")
        #expect(await h.recorder.count == 1)
    }

    /// Multi-process: another process re-authed (new grant, possibly under a
    /// new client) while ours was in flight with the old refresh token. The
    /// refusal is about the old grant — adopt the stored one; no latch, no
    /// announcement, and the registration is left alone.
    @Test("a refusal for a grant the store has moved past adopts the stored tokens")
    func refusalForSupersededGrantAdopts() async throws {
        let store = RecordingAccountStore(clientIDs: [Self.origin.absoluteString: "cid"])
        try store.setTokens(Self.tokens(0, expiresIn: -60), for: Self.accountID)
        let refresher = GatedRefresher { _ in
            try store.setTokens(Self.tokens(7), for: Self.accountID)
            throw OAuthError.server(error: "invalid_client", description: nil)
        }
        let provider = AccountTokenProvider(
            accountID: Self.accountID, store: store, refresher: refresher, refreshLeeway: 60,
            origin: Self.origin, clientID: "cid"
        )
        let recorder = RejectionRecorder()
        await provider.setSessionRejectedHandler { await recorder.record($0.accountID) }

        #expect(try await provider.accessToken() == "access-7")
        #expect(try await provider.accessToken() == "access-7", "a latch was set on the adopted grant")
        #expect(await recorder.count == 0)
        #expect(try store.clientID(for: Self.origin) == "cid")
        #expect(await refresher.callCount == 1)
    }

    /// Callers that JOIN the refused refresh get the public error (never the
    /// internal one), and the death is still announced exactly once.
    @Test("joiners of a refused refresh fail with reauthenticationRequired; one announcement", .timeLimit(.minutes(1)))
    func joinersGetThePublicError() async throws {
        let store = RecordingAccountStore(clientIDs: [Self.origin.absoluteString: "cid"])
        try store.setTokens(Self.tokens(0, expiresIn: -60), for: Self.accountID)
        let refresher = GatedRefresher(released: false) { _ in
            throw OAuthError.server(error: "unauthorized_client", description: nil)
        }
        let provider = AccountTokenProvider(
            accountID: Self.accountID, store: store, refresher: refresher, refreshLeeway: 60,
            origin: Self.origin, clientID: "cid"
        )
        let recorder = RejectionRecorder()
        await provider.setSessionRejectedHandler { await recorder.record($0.accountID) }
        store.resetCounters()

        let callers = (0..<3).map { _ in
            Task { () -> (any Error)? in
                do {
                    _ = try await provider.accessToken()
                    return nil
                } catch {
                    return error
                }
            }
        }
        await store.waitForTokenReads(3)
        await refresher.release()

        for caller in callers {
            let error = await caller.value
            #expect(error as? OAuthError == .reauthenticationRequired)
        }
        #expect(await refresher.callCount == 1)
        #expect(await recorder.count == 1)
        #expect(try store.clientID(for: Self.origin) == nil)
    }

    /// Unchanged: transport trouble and 5xx are still retried once (after the
    /// store re-read), never latched or announced.
    @Test("a 5xx refresh is still retried and succeeds without an announcement")
    func serverErrorStillRetried() async throws {
        let h = try await Self.harness(
            token: FakeResponse(status: 503, body: Data("unavailable".utf8)),
            .json(200, AuthFixtures.tokenJSON(access: "access-1", refresh: "refresh-1"))
        )

        #expect(try await h.provider.refreshAccessToken(failedToken: "access-0") == "access-1")

        #expect(h.server.requests(path: AuthFixtures.tokenPath).count == 2)
        #expect(await h.recorder.count == 0)
        #expect(try h.store.clientID(for: Self.origin) == "cid")
    }

    /// Unchanged: `invalid_grant` still clears the dead grant (and is still
    /// announced once), and it is about the GRANT — the registration stays.
    @Test("invalid_grant still clears the grant and keeps the registration")
    func invalidGrantUnchanged() async throws {
        let h = try await Self.harness(token: .json(400, #"{"error":"invalid_grant"}"#))

        await #expect(throws: OAuthError.reauthenticationRequired) {
            _ = try await h.provider.refreshAccessToken(failedToken: "access-0")
        }

        #expect(try h.store.tokens(for: Self.accountID) == nil)
        #expect(try h.store.clientID(for: Self.origin) == "cid")
        #expect(await h.recorder.count == 1)
    }

    // MARK: - Registration recovery end to end

    /// The whole repair: the refresh is refused as `invalid_client`, the
    /// registration is forgotten, and the next sign-in REGISTERS again and
    /// exchanges its code under the new client. Fails on the pre-fix code with
    /// zero registrations and an exchange sent as the dead `cid_old`.
    @Test("after a client refusal on refresh, the next sign-in registers again")
    @MainActor func nextSignInReRegisters() async throws {
        let server = AuthFixtures.fullServer()
        server.route(
            "POST", AuthFixtures.tokenPath,
            .json(400, #"{"error":"invalid_client","error_description":"missing client"}"#),
            .json(200, AuthFixtures.tokenJSON())
        )
        let store = RecordingAccountStore(clientIDs: [Self.origin.absoluteString: "cid_old"])
        let account = Account(origin: Self.origin, clientID: "cid_old", scopes: [])
        try store.add(account)
        try store.setTokens(Self.tokens(0, expiresIn: -60), for: account.id)
        let coordinator = AuthCoordinator(
            store: store,
            presenter: FakeAuthorizationPresenter.succeeding(),
            session: server.makeSession()
        )
        let provider = try await coordinator.tokenProvider(for: account)
        let recorder = RejectionRecorder()
        await provider.setSessionRejectedHandler { await recorder.record($0.accountID) }

        await #expect(throws: OAuthError.reauthenticationRequired) { _ = try await provider.accessToken() }
        #expect(await recorder.count == 1)
        #expect(try store.clientID(for: Self.origin) == nil)
        let refresh = AuthFixtures.form(try #require(server.requests(path: AuthFixtures.tokenPath).first).bodyText)
        #expect(refresh["client_id"] == "cid_old")

        let signedIn = try await coordinator.addAccount(origin: Self.origin)

        #expect(server.requests(path: AuthFixtures.registerPath).count == 1, "the sign-in reused the refused client")
        #expect(signedIn.clientID == "cid_registered")
        #expect(try store.clientID(for: Self.origin) == "cid_registered")
        #expect(try store.account(id: account.id)?.clientID == "cid_registered")
        let exchange = AuthFixtures.form(try #require(server.requests(path: AuthFixtures.tokenPath).last).bodyText)
        #expect(exchange["client_id"] == "cid_registered")
    }

    // MARK: - Authorization leg

    /// The code exchange itself refused the client: the sign-in fails with the
    /// readable ``OAuthError/clientRegistrationRejected``, the registration is
    /// forgotten, and the NEXT sign-in registers anew.
    @Test("an exchange refusing the client forgets the registration; the retry re-registers")
    @MainActor func exchangeRefusalForgetsRegistration() async throws {
        let server = AuthFixtures.fullServer()
        server.route(
            "POST", AuthFixtures.tokenPath,
            .json(400, #"{"error":"invalid_client"}"#),
            .json(200, AuthFixtures.tokenJSON())
        )
        let store = RecordingAccountStore(clientIDs: [
            Self.origin.absoluteString: "cid_old",
            Self.otherOrigin.absoluteString: "cid_old",
        ])
        let coordinator = AuthCoordinator(
            store: store,
            presenter: FakeAuthorizationPresenter.succeeding(),
            session: server.makeSession()
        )

        await #expect(throws: OAuthError.clientRegistrationRejected) {
            _ = try await coordinator.addAccount(origin: Self.origin)
        }
        #expect(try store.clientID(for: Self.origin) == nil)
        #expect(try store.clientID(for: Self.otherOrigin) == "cid_old")
        #expect(try store.accounts().isEmpty)
        #expect(server.requests(path: AuthFixtures.registerPath).isEmpty)

        let account = try await coordinator.addAccount(origin: Self.origin)
        #expect(account.clientID == "cid_registered")
        #expect(server.requests(path: AuthFixtures.registerPath).count == 1)
    }

    /// A server that DOES redirect a client error to the callback (with our
    /// state) gets the same treatment. With a mismatched state it is a forged
    /// callback and must change nothing.
    @Test("an unauthorized_client callback forgets the registration only when the state matches")
    @MainActor func callbackRefusalForgetsRegistration() async throws {
        for matchingState in [true, false] {
            let server = AuthFixtures.fullServer()
            let store = RecordingAccountStore(clientIDs: [Self.origin.absoluteString: "cid_old"])
            let presenter = FakeAuthorizationPresenter { url in
                let state = matchingState ? (AuthFixtures.query(url)["state"] ?? "") : "forged"
                return URL(string: "com.wizemann.herald:/oauth/callback?error=unauthorized_client&state=\(state)")!
            }
            let coordinator = AuthCoordinator(store: store, presenter: presenter, session: server.makeSession())

            await #expect(throws: matchingState ? OAuthError.clientRegistrationRejected : OAuthError.stateMismatch) {
                _ = try await coordinator.addAccount(origin: Self.origin)
            }
            #expect(try store.clientID(for: Self.origin) == (matchingState ? nil : "cid_old"))
            #expect(server.requests(path: AuthFixtures.tokenPath).isEmpty)
        }
    }

    /// The Keychain store's compare-and-delete, per origin.
    @Test("KeychainAccountStore.forgetClientID removes only a matching id for that origin")
    func keychainForgetClientID() throws {
        let store = KeychainAccountStore(secrets: InMemorySecretStore())
        try store.setClientID("cid", for: Self.origin)
        try store.setClientID("cid", for: Self.otherOrigin)

        #expect(try store.forgetClientID("cid_other", for: Self.origin) == false)
        #expect(try store.clientID(for: Self.origin) == "cid")
        #expect(try store.forgetClientID("cid", for: URL(string: "https://mail.test.invalid/api/v1")!))
        #expect(try store.clientID(for: Self.origin) == nil)
        #expect(try store.clientID(for: Self.otherOrigin) == "cid")
        #expect(try store.forgetClientID("cid", for: Self.origin) == false)
    }

    /// The classification itself.
    @Test("isTerminalRefreshRefusal and isRejectedClient cover exactly the intended codes")
    func classification() {
        let terminal = ["invalid_client", "unauthorized_client", "http_401", "invalid_scope", "invalid_target"]
        for code in terminal {
            #expect(OAuthError.server(error: code, description: nil).isTerminalRefreshRefusal, "\(code)")
        }
        for code in ["invalid_grant", "server_error", "temporarily_unavailable", "http_503", "http_400", "invalid_request", "http_403"] {
            #expect(!OAuthError.server(error: code, description: nil).isTerminalRefreshRefusal, "\(code)")
        }
        #expect(OAuthError.server(error: "invalid_client", description: nil).isRejectedClient)
        #expect(OAuthError.server(error: "unauthorized_client", description: nil).isRejectedClient)
        #expect(!OAuthError.server(error: "http_401", description: nil).isRejectedClient)
        #expect(!OAuthError.transport(.init(URLError(.timedOut))).isTerminalRefreshRefusal)
    }
}
