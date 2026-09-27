import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "accounts")

/// Owns the account list, the per-account OAuth tokens, and the per-origin client
/// registration.
///
/// `nonisolated` so the ``AccountTokenProvider`` actor (and test fakes) can conform
/// and call it synchronously off the main actor.
public nonisolated protocol AccountStore: Sendable {
    /// Every account whose record can be read; an individual record this build
    /// cannot decode is skipped (and kept — see ``add(_:)``).
    ///
    /// Throws ``AccountStoreError/indexUnreadable`` when the stored index is
    /// valid JSON of a shape this build does not understand (a newer build's
    /// format), rather than answering "no accounts": the caller decides what
    /// that means (launch shows onboarding WITH the explanation, and Add Account
    /// refuses before any OAuth). Nothing is ever written over it.
    ///
    /// Bytes that are not JSON at all (a corrupt item) answer "no accounts" —
    /// no format can be waiting for a newer build there — and the next write
    /// first sets them aside under `accounts.index.corrupt.<ms>`, so the store
    /// heals without destroying anything.
    func accounts() throws -> [Account]
    /// Inserts, or updates the record with the same `id` in place — merged, not
    /// replaced (``Account/merging(over:)``), so fields a sign-in cannot know
    /// survive a re-auth.
    ///
    /// Throws ``AccountStoreError/indexUnreadable`` — and writes NOTHING — when
    /// the index is in a format this build cannot read: rewriting it from
    /// "empty" would silently delete every other account and orphan their
    /// tokens. A corrupt (non-JSON) index is backed up first, then replaced.
    func add(_ account: Account) throws
    /// Removes the account, its tokens, and nothing else — the client registration
    /// is not this call's to judge (``AuthCoordinator/signOut(_:)`` forgets it
    /// when no account on the origin remains). Throws
    /// ``AccountStoreError/indexUnreadable`` (writing nothing) like ``add(_:)``.
    func remove(_ accountID: Account.ID) throws

    func tokens(for accountID: Account.ID) throws -> OAuthTokens?
    /// `nil` clears them.
    func setTokens(_ tokens: OAuthTokens?, for accountID: Account.ID) throws
    /// Compare-and-set: writes `tokens` (`nil` clears them) ONLY while the
    /// stored tokens' refresh token is still `expected` — the one the caller
    /// just spent (a refresh) or saw refused (`invalid_grant`). Returns whether
    /// anything was written; an empty store never matches.
    ///
    /// What keeps a refresh that was in flight while a sign-in wrote a NEW
    /// grant (here, in another graph, or in another process) from landing
    /// after it and overwriting it with the old — possibly dead — family (see
    /// ``AccountTokenProvider``). Atomic with every other token read and write
    /// of this conformer; across processes sharing the Keychain it is a
    /// read-then-write with no network in between, so the window it leaves is
    /// microseconds, not a token-endpoint round trip.
    func setTokens(_ tokens: OAuthTokens?, for accountID: Account.ID, ifRefreshTokenIs expected: String) throws -> Bool

    /// The dynamically registered `client_id` for an origin, if Herald already has one.
    func clientID(for origin: URL) throws -> String?
    func setClientID(_ clientID: String, for origin: URL) throws
    /// Forgets the origin's registration, but ONLY while it is still `clientID`
    /// — the one the server just refused. Returns whether anything was removed.
    ///
    /// Compare-and-delete because the item is shared (every Herald process on
    /// the Mac, and every account on that origin): if another process — or a
    /// sign-in here — has already registered anew, its fresh `client_id` must
    /// survive a late report about the old one. Never touches another origin.
    /// The next sign-in finds no registration and registers again
    /// (`AuthCoordinator` treats missing and empty alike).
    @discardableResult
    func forgetClientID(_ clientID: String, for origin: URL) throws -> Bool

    /// The OAuth discovery last resolved for an origin, so an account can come up
    /// (and read its cached mail) with no network. A cache, not a secret: stale
    /// or missing is always recoverable by discovering again.
    func oauthConfiguration(for origin: URL) throws -> OAuthConfiguration?
    /// `nil` forgets it.
    func setOAuthConfiguration(_ configuration: OAuthConfiguration?, for origin: URL) throws

    /// Whether the stored index is DAMAGED — bytes that are not JSON at all —
    /// which ``accounts()`` answers as "no accounts". Lets the launch say why
    /// the accounts are gone instead of opening onboarding without a word.
    /// Reads only; the next write still sets the bytes aside (see
    /// ``accounts()``).
    func accountIndexIsDamaged() throws -> Bool
}

nonisolated extension AccountStore {
    public func account(id: Account.ID) throws -> Account? {
        try accounts().first { $0.id == id }
    }

    /// Default: persists nothing, so every activation discovers lazily. Test
    /// stores that do not care about offline activation inherit this; the
    /// Keychain store overrides it.
    public func oauthConfiguration(for origin: URL) throws -> OAuthConfiguration? { nil }
    public func setOAuthConfiguration(_ configuration: OAuthConfiguration?, for origin: URL) throws {}

    /// Default: nothing to be damaged. The Keychain store overrides it.
    public func accountIndexIsDamaged() throws -> Bool { false }
}

/// Failures of the account index itself (per-item Keychain failures stay
/// ``SecretStoreError``).
public nonisolated enum AccountStoreError: Error, Sendable, Hashable {
    /// The stored account list exists but is not a list Herald can read —
    /// corrupt, or written by a build with an incompatible format. Herald
    /// refuses to change it rather than overwrite it.
    case indexUnreadable
}

nonisolated extension AccountStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .indexUnreadable:
            "Herald can't read its saved list of accounts, so it has left it untouched. "
                + "If you have used a newer version of Herald on this Mac, update this copy and try again."
        }
    }
}

/// Nonisolated JSON conveniences over the raw ``SecretStore`` requirements.
///
/// ``AccountStore`` backed by a ``SecretStore`` — i.e. the Keychain in production.
///
/// Everything, including the account index, goes through the secret store: the index
/// carries `clientID`, and "Herald Error Handling and Security Rules" puts
/// registrations in the Keychain alongside tokens.
public nonisolated final class KeychainAccountStore: AccountStore {
    private let secrets: any SecretStore
    /// Guards every read-modify-write — the account index, the registration's
    /// compare-and-delete, the tokens' compare-and-set — and the plain reads
    /// and writes they must be atomic with; individual `SecItem` calls are
    /// atomic but those sequences are not. Not re-entrant: nothing called
    /// under it may call back into a method that takes it.
    private let lock = OSAllocatedUnfairLock()

    public init(secrets: any SecretStore = KeychainStore()) {
        self.secrets = secrets
    }

    // MARK: Keys

    static let indexKey = "accounts.index"
    static func tokensKey(_ accountID: Account.ID) -> String { "tokens.\(accountID)" }
    static func clientKey(_ origin: URL) -> String { "client.\(Account.normalize(origin).absoluteString)" }
    static func discoveryKey(_ origin: URL) -> String { "discovery.\(Account.normalize(origin).absoluteString)" }

    // MARK: Accounts

    public func accounts() throws -> [Account] {
        try lock.withLock {
            switch try loadIndex() {
            case .missing:
                return []
            case .corrupt:
                logger.fault("account index is not JSON; showing no accounts until the next write sets it aside")
                return []
            case .unreadable:
                // A distinct error, not an empty list: an empty list is what the
                // old code wrote BACK. The app turns it into onboarding with an
                // explanation, so a bad blob never bricks the launch.
                logger.fault("account index unreadable; refusing to overwrite it")
                throw AccountStoreError.indexUnreadable
            case .entries(let entries):
                return entries.compactMap(\.account)
            }
        }
    }

    public func accountIndexIsDamaged() throws -> Bool {
        try lock.withLock {
            if case .corrupt = try loadIndex() { return true }
            return false
        }
    }

    public func add(_ account: Account) throws {
        try lock.withLock {
            var entries = try writableIndex()
            let existing = entries.indices.filter { entries[$0].account?.id == account.id }
            if let first = existing.first, let current = entries[first].account {
                // Updated IN PLACE, over the stored object: keys this build does
                // not know (a newer build's fields) survive the rewrite.
                let merged = account.merging(over: current)
                entries[first] = try IndexEntry(merged, over: entries[first].raw)
                for duplicate in existing.dropFirst().reversed() { entries.remove(at: duplicate) }
            } else {
                entries.append(try IndexEntry(account, over: nil))
            }
            try saveIndex(entries)
        }
    }

    public func remove(_ accountID: Account.ID) throws {
        try lock.withLock {
            var entries = try writableIndex()
            entries.removeAll { $0.account?.id == accountID }
            try saveIndex(entries)
            try secrets.removeValue(for: Self.tokensKey(accountID))
        }
    }

    /// One element of the stored index: the JSON object as stored, and the
    /// ``Account`` it decodes to, if it does. An element that does not decode is
    /// carried through every rewrite untouched — it is someone's account, just
    /// not one this build can read.
    private struct IndexEntry {
        var raw: Any
        var account: Account?

        init(raw: Any) {
            self.raw = raw
            self.account = (try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]))
                .flatMap { try? JSONDecoder().decode(Account.self, from: $0) }
        }

        /// `account` encoded over `previous` (the stored object it replaces), so
        /// unknown keys in `previous` are kept.
        init(_ account: Account, over previous: Any?) throws {
            let encoded: Any
            do {
                encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(account))
            } catch {
                throw SecretStoreError.encodingFailed
            }
            if var object = previous as? [String: Any], let fields = encoded as? [String: Any] {
                for (key, value) in fields { object[key] = value }
                self.raw = object
            } else {
                self.raw = encoded
            }
            self.account = account
        }
    }

    private enum StoredIndex {
        case missing
        /// Not JSON at all: damaged, not a format anyone wrote on purpose.
        case corrupt(Data)
        /// Valid JSON but not the bare array this build writes — very likely a
        /// newer build's format. Never overwritten.
        case unreadable
        case entries([IndexEntry])
    }

    /// Keychain failures propagate; only the CONTENT is judged here.
    private func loadIndex() throws -> StoredIndex {
        guard let data = try secrets.data(for: Self.indexKey), !data.isEmpty else { return .missing }
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .corrupt(data)
        }
        guard let array = parsed as? [Any] else { return .unreadable }
        let entries = array.map(IndexEntry.init(raw:))
        let skipped = entries.filter { $0.account == nil }.count
        if skipped > 0 {
            logger.error("account index has \(skipped, privacy: .public) unreadable entries; kept, not shown")
        }
        return .entries(entries)
    }

    /// The index to modify — or a throw, never an "empty" stand-in for one that
    /// could not be read.
    private func writableIndex() throws -> [IndexEntry] {
        switch try loadIndex() {
        case .missing: return []
        case .corrupt(let data):
            // Set aside BEFORE anything is written over it; a failed backup
            // aborts the write. Recoverable by hand from Keychain Access.
            let backupKey = "\(Self.indexKey).corrupt.\(Int(Date().timeIntervalSince1970 * 1000))"
            try secrets.set(data, for: backupKey)
            logger.fault("account index was not JSON; backed up as \(backupKey, privacy: .public) and starting a new one")
            return []
        case .unreadable:
            logger.fault("account index unreadable; refusing to overwrite it")
            throw AccountStoreError.indexUnreadable
        case .entries(let entries): return entries
        }
    }

    private func saveIndex(_ entries: [IndexEntry]) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: entries.map(\.raw))
        } catch {
            throw SecretStoreError.encodingFailed
        }
        try secrets.set(data, for: Self.indexKey)
    }

    // MARK: Tokens

    /// Token reads and writes take the lock too, so inside this process the
    /// compare-and-set (``setTokens(_:for:ifRefreshTokenIs:)``) is atomic with
    /// every other write — a sign-in's grant can never land between its
    /// compare and its write and then be overwritten.
    public func tokens(for accountID: Account.ID) throws -> OAuthTokens? {
        try lock.withLock { try loadTokens(for: accountID) }
    }

    public func setTokens(_ tokens: OAuthTokens?, for accountID: Account.ID) throws {
        try lock.withLock { try storeTokens(tokens, for: accountID) }
    }

    public func setTokens(_ tokens: OAuthTokens?, for accountID: Account.ID, ifRefreshTokenIs expected: String) throws -> Bool {
        try lock.withLock {
            guard let stored = try loadTokens(for: accountID), stored.refreshToken == expected else { return false }
            try storeTokens(tokens, for: accountID)
            return true
        }
    }

    /// Callers hold ``lock`` (it is not re-entrant: never call the public
    /// token methods from inside it).
    private func loadTokens(for accountID: Account.ID) throws -> OAuthTokens? {
        try secrets.value(OAuthTokens.self, for: Self.tokensKey(accountID))
    }

    /// Callers hold ``lock``.
    private func storeTokens(_ tokens: OAuthTokens?, for accountID: Account.ID) throws {
        guard let tokens else {
            try secrets.removeValue(for: Self.tokensKey(accountID))
            return
        }
        try secrets.setValue(tokens, for: Self.tokensKey(accountID))
    }

    // MARK: Registration

    /// Under the lock, like ``setClientID(_:for:)`` and
    /// ``forgetClientID(_:for:)``: inside this process a read never lands in
    /// the middle of a compare-and-delete.
    public func clientID(for origin: URL) throws -> String? {
        try lock.withLock { try secrets.string(for: Self.clientKey(origin)) }
    }

    /// Under the lock, so a registration written by this process can never be
    /// lost between ``forgetClientID(_:for:)``'s compare and its delete.
    public func setClientID(_ clientID: String, for origin: URL) throws {
        try lock.withLock { try secrets.setString(clientID, for: Self.clientKey(origin)) }
    }

    /// Serialized with this process's registration reads and writes
    /// (``clientID(for:)``, ``setClientID(_:for:)``) and its index work by the
    /// lock, so a registration written here while the compare-and-delete runs
    /// always survives it. Across processes the read-then-delete is not atomic,
    /// and the loser of that race is at worst one extra registration on the
    /// next sign-in (refreshes send the ACCOUNT RECORD's client id, so a lost
    /// `client.<origin>` never breaks a signed-in account).
    @discardableResult
    public func forgetClientID(_ clientID: String, for origin: URL) throws -> Bool {
        try lock.withLock {
            let key = Self.clientKey(origin)
            guard try secrets.string(for: key) == clientID else { return false }
            try secrets.removeValue(for: key)
            return true
        }
    }

    // MARK: Discovery

    /// A stored document that no longer decodes is a cache miss, not an error:
    /// discovery simply runs again.
    public func oauthConfiguration(for origin: URL) throws -> OAuthConfiguration? {
        do {
            return try secrets.value(OAuthConfiguration.self, for: Self.discoveryKey(origin))
        } catch SecretStoreError.decodingFailed {
            logger.warning("persisted discovery unreadable; will rediscover")
            return nil
        }
    }

    public func setOAuthConfiguration(_ configuration: OAuthConfiguration?, for origin: URL) throws {
        guard let configuration else {
            try secrets.removeValue(for: Self.discoveryKey(origin))
            return
        }
        try secrets.setValue(configuration, for: Self.discoveryKey(origin))
    }
}
