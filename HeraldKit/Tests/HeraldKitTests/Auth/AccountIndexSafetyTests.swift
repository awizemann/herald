import Foundation
import Testing
@testable import HeraldKit

/// Audit W2: the account index is ONE Keychain blob shared by every Herald build
/// on the Mac. It used to be read as "empty" whenever it failed to decode — and
/// the next `add` then wrote that empty list back with one account in it,
/// deleting every other account and orphaning their tokens.
@Suite struct AccountIndexSafetyTests {
    private static let indexKey = "accounts.index"

    private static func account(_ origin: String, clientID: String = "cid") -> Account {
        Account(origin: URL(string: origin)!, clientID: clientID, scopes: ["mail:read"])
    }

    /// What the index looks like to `JSONSerialization`, for order-insensitive
    /// comparison of individual entries.
    private static func entries(_ secrets: InMemorySecretStore) throws -> [NSDictionary] {
        let data = try #require(try secrets.data(for: indexKey))
        let array = try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
        return array.compactMap { $0 as? NSDictionary }
    }

    // MARK: Unreadable index

    /// Fails if `add` or `remove` treats an index in a foreign format as empty
    /// and writes over it (the original data-loss path), or if either touches
    /// the tokens.
    @Test(
        "an index in a foreign format makes add and remove throw and stays byte-identical",
        arguments: [
            // A plausible future format: an envelope instead of a bare array.
            Data(#"{"version":2,"accounts":[{"id":"https://a.test.invalid"}]}"#.utf8),
            Data(#""a string""#.utf8),
            Data("42".utf8),
        ]
    )
    func unreadableIndexIsNeverOverwritten(blob: Data) throws {
        let secrets = InMemorySecretStore()
        try secrets.set(blob, for: Self.indexKey)
        let store = KeychainAccountStore(secrets: secrets)
        let existing = OAuthTokens(accessToken: "at", refreshToken: "rt")
        try store.setTokens(existing, for: "https://a.test.invalid")

        #expect(throws: AccountStoreError.indexUnreadable) {
            try store.add(Self.account("https://b.test.invalid"))
        }
        #expect(throws: AccountStoreError.indexUnreadable) {
            try store.remove("https://a.test.invalid")
        }

        #expect(try secrets.data(for: Self.indexKey) == blob, "the unreadable index was rewritten")
        #expect(try store.tokens(for: "https://a.test.invalid") == existing, "remove touched tokens it could not account for")
        // A distinct error, never "no accounts" (which is what used to be
        // written back): the app shows it on the onboarding screen.
        #expect(throws: AccountStoreError.indexUnreadable) { try store.accounts() }
    }

    /// Bytes that are not JSON at all cannot be anybody's format, so refusing
    /// forever would strand the user (nothing in the app can clear the item).
    /// Fails if the store refuses to heal, or heals by DESTROYING the bytes
    /// instead of setting them aside first.
    @Test(
        "a corrupt (non-JSON) index is backed up, then replaced",
        arguments: [Data("not json at all".utf8), Data([0xFF, 0x00, 0x7B]), Data(#"[{"id":"#.utf8)]
    )
    func corruptIndexIsBackedUpThenReplaced(blob: Data) throws {
        let secrets = InMemorySecretStore()
        try secrets.set(blob, for: Self.indexKey)
        let store = KeychainAccountStore(secrets: secrets)

        #expect(try store.accounts().isEmpty)
        try store.add(Self.account("https://b.test.invalid"))

        #expect(try store.accounts().map(\.id) == ["https://b.test.invalid"])
        let backups = secrets.keys.filter { $0.hasPrefix("accounts.index.corrupt.") }
        #expect(backups.count == 1)
        #expect(try backups.first.flatMap { try secrets.data(for: $0) } == blob, "the corrupt bytes were not kept")
    }

    /// An empty item is "no index", not a corrupt one — nothing to back up.
    @Test("an empty index item is treated as missing")
    func emptyIndexIsMissing() throws {
        let secrets = InMemorySecretStore()
        try secrets.set(Data(), for: Self.indexKey)
        let store = KeychainAccountStore(secrets: secrets)
        #expect(try store.accounts().isEmpty)
        try store.add(Self.account("https://a.test.invalid"))
        #expect(secrets.keys.contains { $0.hasPrefix("accounts.index.corrupt.") } == false)
    }

    /// Entries that are not objects at all, and duplicate ids a hand-edited or
    /// racing write could leave. Fails if a non-object entry is dropped by a
    /// rewrite, or if a duplicate id survives an add (two picker rows).
    @Test("non-object entries survive rewrites and duplicate ids collapse on add")
    func nonObjectEntriesAndDuplicates() throws {
        let secrets = InMemorySecretStore()
        let blob = #"[42,{"id":"https://a.test.invalid","origin":"https://a.test.invalid","label":"a","clientID":"c1","scopes":[]},"x",{"id":"https://a.test.invalid","origin":"https://a.test.invalid","label":"a2","clientID":"c1b","scopes":[]}]"#
        try secrets.set(Data(blob.utf8), for: Self.indexKey)
        let store = KeychainAccountStore(secrets: secrets)

        try store.add(Self.account("https://a.test.invalid", clientID: "c2"))

        let data = try #require(try secrets.data(for: Self.indexKey))
        let array = try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
        #expect(array.count == 3)
        #expect(array.first as? Int == 42)
        #expect(array.contains { $0 as? String == "x" })
        #expect(try store.accounts().map(\.clientID) == ["c2"])
        #expect(try store.accounts().first?.label == "a", "the FIRST record is the one updated in place")
    }

    /// A missing index is simply "no accounts yet" — the first add creates it.
    /// Fails if the unreadable-index guard also blocks the first sign-in.
    @Test("a missing index is created by the first add")
    func missingIndexIsCreated() throws {
        let store = KeychainAccountStore(secrets: InMemorySecretStore())
        try store.add(Self.account("https://a.test.invalid"))
        #expect(try store.accounts().map(\.id) == ["https://a.test.invalid"])
    }

    // MARK: Schema tolerance

    /// The exact bytes the RELEASE build writes today (synthesized `Codable`,
    /// `JSONEncoder` defaults). Fails if any change to `Account` stops the
    /// existing users' index from decoding exactly as before.
    @Test("the index the current release writes decodes unchanged")
    func releaseIndexDecodes() throws {
        let secrets = InMemorySecretStore()
        let release = #"[{"id":"https:\/\/mail.example.com","origin":"https:\/\/mail.example.com","label":"mail.example.com","clientID":"cid_1","scopes":["mail:read","mail:write","mail:send","offline_access"]},{"id":"https:\/\/b.example.com","origin":"https:\/\/b.example.com","label":"Work","userEmail":"me@b.example.com","clientID":"cid_2","scopes":[]}]"#
        try secrets.set(Data(release.utf8), for: Self.indexKey)

        let accounts = try KeychainAccountStore(secrets: secrets).accounts()

        #expect(accounts == [
            Account(
                origin: URL(string: "https://mail.example.com")!,
                clientID: "cid_1",
                scopes: ["mail:read", "mail:write", "mail:send", "offline_access"]
            ),
            Account(
                origin: URL(string: "https://b.example.com")!,
                label: "Work",
                userEmail: "me@b.example.com",
                clientID: "cid_2",
                scopes: []
            ),
        ])
    }

    /// The other direction: an OLDER build (the release app shares this
    /// Keychain item) decodes the index with the synthesized, strict `Codable`.
    /// Fails if anything this build writes — including a merged rewrite — would
    /// no longer decode there, which in the old build means "treat as empty and
    /// overwrite".
    @Test("what this build writes still decodes with the release build's strict decoder")
    func writtenIndexDecodesInOlderBuilds() throws {
        struct ReleaseAccount: Decodable {
            let id: String
            let origin: URL
            let label: String
            let userEmail: String?
            let clientID: String
            let scopes: [String]
        }
        let secrets = InMemorySecretStore()
        let store = KeychainAccountStore(secrets: secrets)
        try store.add(Account(origin: URL(string: "https://a.test.invalid")!, label: "Work", clientID: "c1", scopes: ["mail:read"]))
        try store.add(Self.account("https://b.test.invalid"))
        try store.add(Self.account("https://a.test.invalid", clientID: "c2"))

        let data = try #require(try secrets.data(for: Self.indexKey))
        let decoded = try JSONDecoder().decode([ReleaseAccount].self, from: data)
        #expect(decoded.map(\.id) == ["https://a.test.invalid", "https://b.test.invalid"])
        #expect(decoded.map(\.clientID) == ["c2", "cid"])
        #expect(decoded.first?.label == "Work")
    }

    /// Fails if a record missing the fields a sign-in can default (`id`,
    /// `label`, `scopes`) is dropped, or if unknown fields break decoding.
    @Test("a record with missing optional fields and unknown fields still decodes")
    func tolerantDecoding() throws {
        let json = #"{"origin":"https://a.test.invalid","clientID":"cid","sub":"user-1","future":{"x":1}}"#
        let account = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
        #expect(account.id == "https://a.test.invalid")
        #expect(account.label == "a.test.invalid")
        #expect(account.scopes.isEmpty)
        #expect(account.userEmail == nil)
        #expect(account.clientID == "cid")
    }

    /// Fails if ONE unreadable entry takes the whole list with it (the old
    /// all-or-nothing `[Account]` decode), or if a later add/remove drops it.
    @Test("one bad entry neither hides the others nor is lost by add or remove")
    func badEntryIsKept() throws {
        let secrets = InMemorySecretStore()
        // The middle entry has no clientID: this build cannot use it.
        let blob = #"[{"id":"https://a.test.invalid","origin":"https://a.test.invalid","label":"a","clientID":"cid_a","scopes":[]},{"id":"https://bad.test.invalid","origin":"https://bad.test.invalid"},{"id":"https://c.test.invalid","origin":"https://c.test.invalid","label":"c","clientID":"cid_c","scopes":[]}]"#
        try secrets.set(Data(blob.utf8), for: Self.indexKey)
        let store = KeychainAccountStore(secrets: secrets)

        #expect(try store.accounts().map(\.id) == ["https://a.test.invalid", "https://c.test.invalid"])

        try store.add(Self.account("https://d.test.invalid"))
        try store.remove("https://a.test.invalid")

        #expect(try store.accounts().map(\.id) == ["https://c.test.invalid", "https://d.test.invalid"])
        let bad: NSDictionary = ["id": "https://bad.test.invalid", "origin": "https://bad.test.invalid"]
        #expect(try Self.entries(secrets).contains(bad), "the unreadable entry was dropped by a rewrite")
    }

    // MARK: Merge, not replace

    /// Fails if a re-auth (which builds its record from scratch) wipes a
    /// label or address the account already had, or moves it in the list.
    @Test("re-adding an account keeps its label and address and its position")
    func reauthMergesFields() throws {
        let store = KeychainAccountStore(secrets: InMemorySecretStore())
        try store.add(Account(
            origin: URL(string: "https://a.test.invalid")!,
            label: "Work",
            userEmail: "me@a.test.invalid",
            clientID: "cid_1",
            scopes: ["mail:read"]
        ))
        try store.add(Self.account("https://b.test.invalid"))

        try store.add(Account(origin: URL(string: "https://a.test.invalid")!, clientID: "cid_2", scopes: ["mail:send"]))

        let accounts = try store.accounts()
        #expect(accounts.map(\.id) == ["https://a.test.invalid", "https://b.test.invalid"])
        let merged = try #require(accounts.first)
        #expect(merged.label == "Work")
        #expect(merged.userEmail == "me@a.test.invalid")
        #expect(merged.clientID == "cid_2", "the new registration must win")
        #expect(merged.scopes == ["mail:send"], "the new grant's scopes must win")
    }

    /// An explicit new value is not a default: it wins.
    @Test("an explicit label or address on the new record wins")
    func explicitValuesWin() throws {
        let store = KeychainAccountStore(secrets: InMemorySecretStore())
        try store.add(Account(origin: URL(string: "https://a.test.invalid")!, label: "Old", userEmail: "old@x", clientID: "c", scopes: []))
        try store.add(Account(origin: URL(string: "https://a.test.invalid")!, label: "New", userEmail: "new@x", clientID: "c", scopes: []))
        let account = try #require(try store.accounts().first)
        #expect(account.label == "New")
        #expect(account.userEmail == "new@x")
    }

    /// A NEWER build's fields on an entry this build rewrites (a re-auth here)
    /// must survive. Fails if the entry is re-encoded from `Account` alone.
    @Test("rewriting an entry keeps fields this build does not know")
    func unknownFieldsSurviveRewrite() throws {
        let secrets = InMemorySecretStore()
        let blob = #"[{"id":"https://a.test.invalid","origin":"https://a.test.invalid","label":"a","clientID":"cid_1","scopes":[],"sub":"user-1"}]"#
        try secrets.set(Data(blob.utf8), for: Self.indexKey)
        let store = KeychainAccountStore(secrets: secrets)

        try store.add(Self.account("https://a.test.invalid", clientID: "cid_2"))

        let entry = try #require(try Self.entries(secrets).first)
        #expect(entry["sub"] as? String == "user-1")
        #expect(entry["clientID"] as? String == "cid_2")
    }

    // MARK: Persisted discovery

    /// Fails if the persisted discovery is keyed by anything but the normalized
    /// origin, or if an unreadable copy is an error rather than a miss.
    @Test("persisted discovery round-trips per origin and an unreadable copy is a miss")
    func discoveryRoundTrip() throws {
        let secrets = InMemorySecretStore()
        let store = KeychainAccountStore(secrets: secrets)

        try store.setOAuthConfiguration(AuthFixtures.configuration, for: URL(string: "https://mail.test.invalid/")!)
        #expect(try store.oauthConfiguration(for: AuthFixtures.origin) == AuthFixtures.configuration)
        #expect(try secrets.data(for: "discovery.https://mail.test.invalid") != nil)
        #expect(try store.oauthConfiguration(for: URL(string: "https://other.test.invalid")!) == nil)

        try secrets.set(Data("garbage".utf8), for: "discovery.https://mail.test.invalid")
        #expect(try store.oauthConfiguration(for: AuthFixtures.origin) == nil)

        try store.setOAuthConfiguration(nil, for: AuthFixtures.origin)
        #expect(try secrets.data(for: "discovery.https://mail.test.invalid") == nil)
    }
}
