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
        self.label = label ?? Account.defaultLabel(for: normalized)
        self.userEmail = userEmail
        self.clientID = clientID
        self.scopes = scopes
    }

    enum CodingKeys: String, CodingKey {
        case id, origin, label, userEmail, clientID, scopes
    }

    /// Tolerant on purpose: the index is one Keychain blob shared by every Herald
    /// build on the Mac (a release app and a dev copy), so a record written by a
    /// newer or older build must still decode. Only `origin` and `clientID` are
    /// required — without them there is no account to refresh. Everything else
    /// falls back to what ``init(id:origin:label:userEmail:clientID:scopes:)``
    /// would have chosen, and unknown keys are ignored. The ENCODED shape is
    /// unchanged (all six keys), so older builds keep reading what this one
    /// writes. See "Herald Architecture" (#account-index).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let origin = try container.decode(URL.self, forKey: .origin)
        self.origin = origin
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? Account.normalize(origin).absoluteString
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
            ?? Account.defaultLabel(for: origin)
        self.userEmail = try container.decodeIfPresent(String.self, forKey: .userEmail)
        self.clientID = try container.decode(String.self, forKey: .clientID)
        self.scopes = try container.decodeIfPresent([String].self, forKey: .scopes) ?? []
    }

    /// What ``label`` defaults to for an origin: its host.
    public static func defaultLabel(for origin: URL) -> String {
        let normalized = normalize(origin)
        return normalized.host ?? normalized.absoluteString
    }

    /// This record written over `existing` (same id): the incoming values win,
    /// except the ones a sign-in cannot know — a `userEmail` it did not learn,
    /// and a `label` it only defaulted — which keep what `existing` had.
    ///
    /// A re-auth builds its record from scratch (origin, client id, scopes), so a
    /// plain replace would silently drop a label the user chose or an address
    /// `/me` disclosed (neither is set by anything yet; the multi-account
    /// picker will). It assumes both records are the SAME user: once identity
    /// is origin+sub, only merge records whose identity matches.
    public func merging(over existing: Account) -> Account {
        var merged = self
        if merged.userEmail == nil { merged.userEmail = existing.userEmail }
        if merged.label == Account.defaultLabel(for: merged.origin) { merged.label = existing.label }
        return merged
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

    /// Bounds for the *jittered* proactive refresh window.
    ///
    /// Two Herald processes (a release build and a dev copy) share one Keychain
    /// item, so a fixed leeway makes both wake on the same token at the same
    /// instant and race to redeem the same rotated refresh token. A per-provider
    /// random window spreads them out; it reduces the race, it does not remove it —
    /// ``AccountTokenProvider``'s re-read-before-refresh is the correctness fix.
    public static let refreshLeewayRange: ClosedRange<TimeInterval> = 60...180

    /// A fresh draw from ``refreshLeewayRange``. One per provider, not per call:
    /// a leeway that moved on every call would flap a token in and out of "usable".
    public static func jitteredRefreshLeeway() -> TimeInterval {
        .random(in: refreshLeewayRange)
    }
}
