import Foundation
import Testing
@testable import HeraldKit

@Suite struct SecretStoreTests {
    struct Registration: Codable, Hashable {
        let clientID: String
        let scopes: [String]
    }

    /// The Codable convenience is what auth will store registrations with; this
    /// fails if encode/decode is wired to the wrong key or silently returns nil.
    @Test("Codable values round-trip and deletion actually removes the key")
    func codableRoundTrip() throws {
        let store = InMemorySecretStore()
        let registration = Registration(clientID: "cid_1", scopes: ["mail:read", "mail:send"])

        try store.setValue(registration, for: "https://mail.test.invalid")
        #expect(try store.value(Registration.self, for: "https://mail.test.invalid") == registration)

        try store.removeValue(for: "https://mail.test.invalid")
        #expect(try store.value(Registration.self, for: "https://mail.test.invalid") == nil)
    }

    @Test("Reading an absent key returns nil rather than throwing")
    func missingKeyIsNil() throws {
        let store = InMemorySecretStore()
        #expect(try store.data(for: "nothing") == nil)
        #expect(try store.string(for: "nothing") == nil)
    }

    @Test("A stored value that is not the expected shape throws .decodingFailed")
    func decodeMismatchThrows() throws {
        let store = InMemorySecretStore()
        try store.setString("not json", for: "key")

        #expect(throws: SecretStoreError.decodingFailed) {
            _ = try store.value(Registration.self, for: "key")
        }
    }

    @Test("KeychainStore overwrites rather than duplicating an existing item")
    func keychainOverwrites() throws {
        // Uses a throwaway service so it cannot collide with the real app's items.
        let store = KeychainStore(service: "com.wizemann.herald.tests.\(UUID().uuidString)")
        let key = "access-token"
        defer { try? store.removeValue(for: key) }

        do {
            try store.setString("first", for: key)
        } catch SecretStoreError.keychain(let status) {
            // swift test runs unsigned; the Keychain may be unavailable in CI.
            try #require(Bool(false), "keychain unavailable (OSStatus \(status))")
            return
        }

        try store.setString("second", for: key)
        // A missing update path would leave "first" (or fail with errSecDuplicateItem).
        #expect(try store.string(for: key) == "second")

        try store.removeValue(for: key)
        #expect(try store.data(for: key) == nil)
    }
}
