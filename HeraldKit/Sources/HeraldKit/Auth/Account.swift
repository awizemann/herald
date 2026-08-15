import Foundation

/// One HQBase server the user has signed into.
///
/// HQBase is self-hosted per customer, so an account IS an origin plus the OAuth
/// client that was dynamically registered against it (see "Herald Project Overview").
/// The value itself is not secret, but it is persisted inside the Keychain blob the
/// ``AccountStore`` owns so the `clientID` never lands in UserDefaults.
public nonisolated struct Account: Sendable, Codable, Hashable, Identifiable {
    /// Stable key for tokens and registration lookups; defaults to the normalized origin.
    public let id: String
    /// e.g. `https://mail.example.com` — no path.
    public let origin: URL
    /// What the account picker shows. Defaults to the origin's host.
    public var label: String
    /// The signed-in user's address, when the token response or `/me` disclosed one.
    public var userEmail: String?
    /// Client id from dynamic client registration against `origin`.
    public var clientID: String
    /// Scopes actually granted (server echoes them on the token response).
    public var scopes: [String]

    public init(
        id: String? = nil,
        origin: URL,
        label: String? = nil,
        userEmail: String? = nil,
        clientID: String,
        scopes: [String]
    ) {
        let normalized = Account.normalize(origin)
        self.id = id ?? normalized.absoluteString
        self.origin = normalized
        self.label = label ?? normalized.host ?? normalized.absoluteString
        self.userEmail = userEmail
        self.clientID = clientID
        self.scopes = scopes
    }

    /// Scheme + host + port only, with no trailing slash, so `https://x/` and
    /// `https://x` are the same account (and produce the same Keychain keys).
    public static func normalize(_ origin: URL) -> URL {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { return origin }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url ?? origin
    }

    /// The audience every Mail API token must be bound to.
    /// Tokens minted for `/mcp` do not work here — see "HQBase Mail API v1 Contract".
    public var resource: String { Account.resource(for: origin) }

    public static func resource(for origin: URL) -> String {
        normalize(origin).absoluteString + "/api/v1"
    }
}

/// The OAuth material for one account. Lives only in the Keychain.
public nonisolated struct OAuthTokens: Sendable, Codable, Hashable {
    public var accessToken: String
    public var refreshToken: String?
    /// Absolute expiry, derived from `expires_in` at the time of the token response.
    public var expiresAt: Date?
    /// Space-delimited granted scope, as the server returned it.
    public var scope: String

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, scope: String = "") {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    public var scopes: [String] { scope.split(separator: " ").map(String.init) }

    /// A token with no expiry is treated as usable — the server is the final judge
    /// and ``AuthenticatingMiddleware`` still refreshes once on a 401.
    public func isUsable(at now: Date = Date(), leeway: TimeInterval = OAuthTokens.refreshLeeway) -> Bool {
        guard let expiresAt else { return true }
        return now.addingTimeInterval(leeway) < expiresAt
    }

    /// Refresh this long before the token actually expires.
    public static let refreshLeeway: TimeInterval = 60
}
