import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "accounts")

/// Owns the account list, the per-account OAuth tokens, and the per-origin client
/// registration.
///
/// `nonisolated` so the ``AccountTokenProvider`` actor (and test fakes) can conform
/// and call it synchronously off the main actor.
public nonisolated protocol AccountStore: Sendable {
    func accounts() throws -> [Account]
    /// Inserts or replaces by `id`.
    func add(_ account: Account) throws
    /// Removes the account, its tokens, and nothing else — the client registration
    /// survives so re-adding the same origin does not re-register.
    func remove(_ accountID: Account.ID) throws

    func tokens(for accountID: Account.ID) throws -> OAuthTokens?
    /// `nil` clears them.
    func setTokens(_ tokens: OAuthTokens?, for accountID: Account.ID) throws

    /// The dynamically registered `client_id` for an origin, if Herald already has one.
    func clientID(for origin: URL) throws -> String?
    func setClientID(_ clientID: String, for origin: URL) throws
}

nonisolated extension AccountStore {
    public func account(id: Account.ID) throws -> Account? {
        try accounts().first { $0.id == id }
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
    /// Guards the read-modify-write of the account index; individual `SecItem`
    /// calls are atomic but the index is not.
    private let lock = OSAllocatedUnfairLock()

    public init(secrets: any SecretStore = KeychainStore()) {
        self.secrets = secrets
    }

    // MARK: Keys

    static let indexKey = "accounts.index"
    static func tokensKey(_ accountID: Account.ID) -> String { "tokens.\(accountID)" }
    static func clientKey(_ origin: URL) -> String { "client.\(Account.normalize(origin).absoluteString)" }

    // MARK: Accounts

    public func accounts() throws -> [Account] {
        try lock.withLock { try loadIndex() }
    }

    public func add(_ account: Account) throws {
        try lock.withLock {
            var index = try loadIndex()
            index.removeAll { $0.id == account.id }
            index.append(account)
            try secrets.setValue(index, for: Self.indexKey)
        }
    }

    public func remove(_ accountID: Account.ID) throws {
        try lock.withLock {
            var index = try loadIndex()
            index.removeAll { $0.id == accountID }
            try secrets.setValue(index, for: Self.indexKey)
            try secrets.removeValue(for: Self.tokensKey(accountID))
        }
    }

    private func loadIndex() throws -> [Account] {
        do {
            return try secrets.value([Account].self, for: Self.indexKey) ?? []
        } catch SecretStoreError.decodingFailed {
            // A stored index we cannot read is unrecoverable; treat it as empty and
            // let the user re-add rather than blocking launch forever.
            logger.error("account index unreadable; starting empty")
            return []
        }
    }

    // MARK: Tokens

    public func tokens(for accountID: Account.ID) throws -> OAuthTokens? {
        try secrets.value(OAuthTokens.self, for: Self.tokensKey(accountID))
    }

    public func setTokens(_ tokens: OAuthTokens?, for accountID: Account.ID) throws {
        guard let tokens else {
            try secrets.removeValue(for: Self.tokensKey(accountID))
            return
        }
        try secrets.setValue(tokens, for: Self.tokensKey(accountID))
    }

    // MARK: Registration

    public func clientID(for origin: URL) throws -> String? {
        try secrets.string(for: Self.clientKey(origin))
    }

    public func setClientID(_ clientID: String, for origin: URL) throws {
        try secrets.setString(clientID, for: Self.clientKey(origin))
    }
}
