import Foundation
import Testing
@testable import HeraldKit

@Suite struct AccountStoreTests {
    private func store() -> KeychainAccountStore {
        KeychainAccountStore(secrets: InMemorySecretStore())
    }

    private func account(_ origin: String, clientID: String = "cid") -> Account {
        Account(origin: URL(string: origin)!, clientID: clientID, scopes: ["mail:read"])
    }

    /// Fails if adding the same origin twice duplicates it, or if `add` appends
    /// rather than replacing — a re-sign-in would leave two rows in the picker.
    @Test("adding the same account twice replaces rather than duplicates it")
    func addReplaces() throws {
        let store = store()
        try store.add(account("https://a.test.invalid", clientID: "cid_1"))
        try store.add(account("https://a.test.invalid", clientID: "cid_2"))
        try store.add(account("https://b.test.invalid"))

        #expect(try store.accounts().count == 2)
        #expect(try store.account(id: "https://a.test.invalid")?.clientID == "cid_2")
    }

    /// Trailing slashes and paths must not create a second account or a second set of
    /// Keychain keys. Fails if the origin is used raw.
    @Test("origins are normalized so a trailing slash is the same account")
    func originsAreNormalized() throws {
        let store = store()
        try store.add(account("https://a.test.invalid/"))
        try store.setClientID("cid_norm", for: URL(string: "https://a.test.invalid/api/v1")!)

        #expect(try store.accounts().map(\.id) == ["https://a.test.invalid"])
        #expect(try store.clientID(for: URL(string: "https://a.test.invalid")!) == "cid_norm")
    }

    /// Fails if removal leaves the tokens behind (a real Keychain leak) or takes the
    /// registration with it.
    @Test("remove deletes the account and its tokens but not the registration")
    func removeClearsTokensOnly() throws {
        let store = store()
        let account = account("https://a.test.invalid")
        try store.add(account)
        try store.setClientID("cid_1", for: account.origin)
        try store.setTokens(OAuthTokens(accessToken: "at", refreshToken: "rt"), for: account.id)

        try store.remove(account.id)

        #expect(try store.accounts().isEmpty)
        #expect(try store.tokens(for: account.id) == nil)
        #expect(try store.clientID(for: account.origin) == "cid_1")
    }

    /// Fails if tokens are stored anywhere but the secret store, or under a key that
    /// collides with the account index.
    @Test("tokens round-trip through the secret store under a per-account key")
    func tokensRoundTrip() throws {
        let secrets = InMemorySecretStore()
        let store = KeychainAccountStore(secrets: secrets)
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let tokens = OAuthTokens(accessToken: "at", refreshToken: "rt", expiresAt: expiry, scope: "mail:read")

        try store.setTokens(tokens, for: "https://a.test.invalid")
        #expect(try store.tokens(for: "https://a.test.invalid") == tokens)
        #expect(try secrets.data(for: "tokens.https://a.test.invalid") != nil)

        try store.setTokens(nil, for: "https://a.test.invalid")
        #expect(try store.tokens(for: "https://a.test.invalid") == nil)
    }

    /// The 60s leeway drives every refresh decision; fails if the comparison is
    /// inverted or the leeway is ignored.
    @Test("isUsable applies the leeway and treats a missing expiry as usable")
    func usabilityWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(OAuthTokens(accessToken: "a", expiresAt: now.addingTimeInterval(120)).isUsable(at: now))
        #expect(!OAuthTokens(accessToken: "a", expiresAt: now.addingTimeInterval(30)).isUsable(at: now))
        #expect(!OAuthTokens(accessToken: "a", expiresAt: now.addingTimeInterval(-1)).isUsable(at: now))
        #expect(OAuthTokens(accessToken: "a").isUsable(at: now))
    }
}
