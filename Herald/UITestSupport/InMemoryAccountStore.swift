#if DEBUG
import Foundation
import HeraldKit
import os

/// An ``AccountStore`` that never touches the Keychain, so the app-hosted suites
/// can drive `AuthCoordinator.signOut` without a real signed-in account (and
/// without the login-keychain prompt a test run must never provoke). Also the
/// UI-test harness's account store — which is why it lives in the app target,
/// Debug-only, rather than in HeraldTests.
///
/// `os_unfair_lock` rather than an actor, for the reason recorded in "Herald
/// Concurrency Rules": `AccountStore` is a deliberately synchronous `nonisolated
/// protocol` and an actor cannot satisfy it.
nonisolated final class InMemoryAccountStore: AccountStore {
    private struct State {
        var accounts: [Account] = []
        var tokens: [Account.ID: OAuthTokens] = [:]
        var clientIDs: [String: String] = [:]
        var configurations: [String: OAuthConfiguration] = [:]
        var configurationReads: [String] = []
        var refusesAccountList = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(accounts: [Account] = []) {
        state.withLock { $0.accounts = accounts }
    }

    func accounts() throws -> [Account] {
        try state.withLock { state in
            if state.refusesAccountList { throw AccountStoreError.indexUnreadable }
            return state.accounts
        }
    }

    /// Fault injection: while `true`, ``accounts()``, ``add(_:)`` and
    /// ``remove(_:)`` throw `AccountStoreError.indexUnreadable` — the
    /// unreadable-index shape that makes a sign-out unable to finish.
    var refusesAccountList: Bool {
        get { state.withLock { $0.refusesAccountList } }
        set { state.withLock { $0.refusesAccountList = newValue } }
    }

    func add(_ account: Account) throws {
        try state.withLock { state in
            if state.refusesAccountList { throw AccountStoreError.indexUnreadable }
            // Merged in place, like the Keychain store.
            if let index = state.accounts.firstIndex(where: { $0.id == account.id }) {
                state.accounts[index] = account.merging(over: state.accounts[index])
            } else {
                state.accounts.append(account)
            }
        }
    }

    func remove(_ accountID: Account.ID) throws {
        try state.withLock { state in
            if state.refusesAccountList { throw AccountStoreError.indexUnreadable }
            state.accounts.removeAll { $0.id == accountID }
            state.tokens[accountID] = nil
        }
    }

    func tokens(for accountID: Account.ID) throws -> OAuthTokens? {
        state.withLock { $0.tokens[accountID] }
    }

    func setTokens(_ tokens: OAuthTokens?, for accountID: Account.ID) throws {
        state.withLock { $0.tokens[accountID] = tokens }
    }

    /// Compare-and-set under the one lock, like the Keychain store.
    func setTokens(_ tokens: OAuthTokens?, for accountID: Account.ID, ifRefreshTokenIs expected: String) throws -> Bool {
        state.withLock { state in
            guard let stored = state.tokens[accountID], stored.refreshToken == expected else { return false }
            state.tokens[accountID] = tokens
            return true
        }
    }

    func clientID(for origin: URL) throws -> String? {
        state.withLock { $0.clientIDs[Account.normalize(origin).absoluteString] }
    }

    func setClientID(_ clientID: String, for origin: URL) throws {
        state.withLock { $0.clientIDs[Account.normalize(origin).absoluteString] = clientID }
    }

    func forgetClientID(_ clientID: String, for origin: URL) throws -> Bool {
        state.withLock { state in
            let key = Account.normalize(origin).absoluteString
            guard state.clientIDs[key] == clientID else { return false }
            state.clientIDs[key] = nil
            return true
        }
    }

    func oauthConfiguration(for origin: URL) throws -> OAuthConfiguration? {
        let key = Account.normalize(origin).absoluteString
        return state.withLock { state in
            state.configurationReads.append(key)
            return state.configurations[key]
        }
    }

    func setOAuthConfiguration(_ configuration: OAuthConfiguration?, for origin: URL) throws {
        state.withLock { $0.configurations[Account.normalize(origin).absoluteString] = configuration }
    }

    /// Every origin whose persisted discovery was read — one per activation that
    /// found no live discovery, so it doubles as "was this account activated".
    var configurationReads: [String] { state.withLock { $0.configurationReads } }
}
#endif
