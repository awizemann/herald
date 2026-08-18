import Foundation
import HeraldKit
import os

/// An ``AccountStore`` that never touches the Keychain, so the app-hosted suites
/// can drive `AuthCoordinator.signOut` without a real signed-in account (and
/// without the login-keychain prompt a test run must never provoke).
///
/// `os_unfair_lock` rather than an actor, for the reason recorded in "Herald
/// Concurrency Rules": `AccountStore` is a deliberately synchronous `nonisolated
/// protocol` and an actor cannot satisfy it.
nonisolated final class InMemoryAccountStore: AccountStore {
    private struct State {
        var accounts: [Account] = []
        var tokens: [Account.ID: OAuthTokens] = [:]
        var clientIDs: [String: String] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(accounts: [Account] = []) {
        state.withLock { $0.accounts = accounts }
    }

    func accounts() throws -> [Account] { state.withLock { $0.accounts } }

    func add(_ account: Account) throws {
        state.withLock { state in
            state.accounts.removeAll { $0.id == account.id }
            state.accounts.append(account)
        }
    }

    func remove(_ accountID: Account.ID) throws {
        state.withLock { state in
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

    func clientID(for origin: URL) throws -> String? {
        state.withLock { $0.clientIDs[Account.normalize(origin).absoluteString] }
    }

    func setClientID(_ clientID: String, for origin: URL) throws {
        state.withLock { $0.clientIDs[Account.normalize(origin).absoluteString] = clientID }
    }
}
