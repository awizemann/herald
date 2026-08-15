import Foundation
import HeraldKit

// MARK: - Server fixtures

nonisolated enum AuthFixtures {
    static let origin = URL(string: "https://mail.test.invalid")!
    static let resource = "https://mail.test.invalid/api/v1"

    static let protectedResourcePath = "/.well-known/oauth-protected-resource/api/v1"
    /// RFC 8414 path-suffixed form. HQBase's issuer is `{origin}/api/auth`.
    static let suffixedMetadataPath = "/.well-known/oauth-authorization-server/api/auth"
    static let bareMetadataPath = "/.well-known/oauth-authorization-server"
    static let authorizePath = "/api/auth/oauth2/authorize"
    static let tokenPath = "/api/auth/oauth2/token"
    static let registerPath = "/api/auth/oauth2/register"

    static let protectedResourceJSON = """
    {"resource":"\(resource)",
     "authorization_servers":["https://mail.test.invalid/api/auth"],
     "scopes_supported":["mail:read","mail:write","mail:send","offline_access"],
     "bearer_methods_supported":["header"]}
    """

    static let serverMetadataJSON = """
    {"issuer":"https://mail.test.invalid/api/auth",
     "authorization_endpoint":"https://mail.test.invalid\(authorizePath)",
     "token_endpoint":"https://mail.test.invalid\(tokenPath)",
     "registration_endpoint":"https://mail.test.invalid\(registerPath)",
     "device_authorization_endpoint":"https://mail.test.invalid/api/auth/oauth2/device/code",
     "code_challenge_methods_supported":["S256"]}
    """

    static func tokenJSON(
        access: String = "hqb_access_1",
        refresh: String? = "hqb_refresh_1",
        expiresIn: Int = 3600
    ) -> String {
        let refreshField = refresh.map { "\"refresh_token\":\"\($0)\"," } ?? ""
        return """
        {"access_token":"\(access)","token_type":"Bearer",\(refreshField)
         "expires_in":\(expiresIn),"scope":"mail:read mail:write mail:send offline_access"}
        """
    }

    static let metadata = OAuthServerMetadata(
        issuer: "https://mail.test.invalid/api/auth",
        authorizationEndpoint: URL(string: "https://mail.test.invalid\(authorizePath)")!,
        tokenEndpoint: URL(string: "https://mail.test.invalid\(tokenPath)")!,
        registrationEndpoint: URL(string: "https://mail.test.invalid\(registerPath)")!
    )

    static let configuration = OAuthConfiguration(
        origin: origin,
        server: metadata,
        resource: resource,
        scopes: OAuthDiscovery.defaultScopes
    )

    /// A server wired for the whole happy path.
    static func fullServer() -> FakeServer {
        let server = FakeServer()
        server.route("GET", protectedResourcePath, .json(200, protectedResourceJSON))
        server.route("GET", suffixedMetadataPath, .json(200, serverMetadataJSON))
        server.route("POST", registerPath, .json(201, #"{"client_id":"cid_registered","scope":"mail:read mail:write mail:send offline_access"}"#))
        server.route("POST", tokenPath, .json(200, tokenJSON()))
        return server
    }

    /// Parses a form-encoded body into a dictionary.
    static func form(_ body: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            fields[parts[0].removingPercentEncoding ?? parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return fields
    }

    static func query(_ url: URL) -> [String: String] {
        var fields: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            fields[item.name] = item.value
        }
        return fields
    }
}

// MARK: - Presenter fake

/// Stands in for `ASWebAuthenticationSession`: records the URL it was handed and
/// replies with a callback built from a caller-supplied rule.
nonisolated final class FakeAuthorizationPresenter: AuthorizationPresenter, @unchecked Sendable {
    typealias Responder = @Sendable (URL) throws -> URL

    private let lock = NSLock()
    private var seen: [URL] = []
    private let responder: Responder

    init(responder: @escaping Responder) {
        self.responder = responder
    }

    /// Echoes back `state` with a fixed code — the normal success case.
    static func succeeding(code: String = "auth_code_1") -> FakeAuthorizationPresenter {
        FakeAuthorizationPresenter { url in
            let state = AuthFixtures.query(url)["state"] ?? ""
            return URL(string: "herald://oauth/callback?code=\(code)&state=\(state)")!
        }
    }

    var authorizationURLs: [URL] { lock.withLock { seen } }

    func authorize(url: URL, callbackScheme: String) async throws -> URL {
        lock.withLock { seen.append(url) }
        return try responder(url)
    }
}

// MARK: - Account store fake

/// In-memory ``AccountStore`` that counts token reads and can signal when a given
/// number have happened — the deterministic gate for the concurrent-refresh test.
///
/// The count is meaningful because ``AccountTokenProvider/accessToken()`` reads the
/// store and then either starts or joins the refresh with no suspension in between:
/// once N reads have landed, all N callers are provably inside.
nonisolated final class RecordingAccountStore: AccountStore, @unchecked Sendable {
    private let lock = NSLock()
    private var accountList: [Account] = []
    private var tokenStore: [String: OAuthTokens] = [:]
    private var clientIDs: [String: String] = [:]
    private var reads = 0
    private var waiters: [(needed: Int, continuation: CheckedContinuation<Void, Never>)] = []

    private(set) var writes = 0

    init(clientIDs: [String: String] = [:]) {
        self.clientIDs = clientIDs
    }

    func accounts() throws -> [Account] { lock.withLock { accountList } }

    func add(_ account: Account) throws {
        lock.withLock {
            accountList.removeAll { $0.id == account.id }
            accountList.append(account)
        }
    }

    func remove(_ accountID: Account.ID) throws {
        lock.withLock {
            accountList.removeAll { $0.id == accountID }
            tokenStore[accountID] = nil
        }
    }

    func tokens(for accountID: Account.ID) throws -> OAuthTokens? {
        let (tokens, ready) = lock.withLock { () -> (OAuthTokens?, [CheckedContinuation<Void, Never>]) in
            reads += 1
            let satisfied = waiters.filter { $0.needed <= reads }
            waiters.removeAll { $0.needed <= reads }
            return (tokenStore[accountID], satisfied.map(\.continuation))
        }
        for continuation in ready { continuation.resume() }
        return tokens
    }

    func setTokens(_ tokens: OAuthTokens?, for accountID: Account.ID) throws {
        lock.withLock {
            writes += 1
            tokenStore[accountID] = tokens
        }
    }

    func clientID(for origin: URL) throws -> String? {
        lock.withLock { clientIDs[Account.normalize(origin).absoluteString] }
    }

    func setClientID(_ clientID: String, for origin: URL) throws {
        lock.withLock { clientIDs[Account.normalize(origin).absoluteString] = clientID }
    }

    var tokenReadCount: Int { lock.withLock { reads } }

    /// Zeroes the read/write counters so test setup does not show up in assertions.
    func resetCounters() {
        lock.withLock {
            reads = 0
            writes = 0
        }
    }

    /// Suspends until `tokens(for:)` has been called at least `count` times.
    func waitForTokenReads(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let alreadyThere = lock.withLock { () -> Bool in
                if reads >= count { return true }
                waiters.append((count, continuation))
                return false
            }
            if alreadyThere { continuation.resume() }
        }
    }
}

// MARK: - Refresher fake

/// A ``TokenRefreshing`` that counts calls and can hold the first one open until the
/// test releases it — no sleeps, no timing assumptions.
actor GatedRefresher: TokenRefreshing {
    private(set) var callCount = 0
    private(set) var refreshTokensSeen: [String] = []
    /// Holds EVERY gated caller, not just the first: an unserialized provider must
    /// fail the call-count assertion rather than deadlock on a lost continuation.
    private var gate: [CheckedContinuation<Void, Never>] = []
    private var released: Bool
    private let result: @Sendable (Int) throws -> OAuthTokens

    init(released: Bool = true, result: @escaping @Sendable (Int) throws -> OAuthTokens) {
        self.released = released
        self.result = result
    }

    /// Hands out `access-N` on the Nth refresh.
    static func counting(released: Bool = true) -> GatedRefresher {
        GatedRefresher(released: released) { count in
            OAuthTokens(
                accessToken: "access-\(count)",
                refreshToken: "refresh-\(count)",
                expiresAt: Date().addingTimeInterval(3600),
                scope: "mail:read offline_access"
            )
        }
    }

    static func failing(with error: any Error) -> GatedRefresher {
        GatedRefresher { _ in throw error }
    }

    nonisolated func refresh(refreshToken: String) async throws -> OAuthTokens {
        try await record(refreshToken)
    }

    private func record(_ refreshToken: String) async throws -> OAuthTokens {
        callCount += 1
        refreshTokensSeen.append(refreshToken)
        let count = callCount
        if !released {
            await withCheckedContinuation { continuation in
                if released { continuation.resume() } else { gate.append(continuation) }
            }
        }
        return try result(count)
    }

    func release() {
        released = true
        for continuation in gate { continuation.resume() }
        gate.removeAll()
    }
}
