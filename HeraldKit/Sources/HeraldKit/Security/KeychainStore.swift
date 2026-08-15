import Foundation
import Security
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "keychain")

/// Generic-password Keychain storage for OAuth tokens and client registrations.
///
/// Secret VALUES are never logged — only keys and `OSStatus` codes.
public nonisolated struct KeychainStore: SecretStore {
    public static let defaultService = "com.wizemann.herald"

    /// `kSecAttrService`. Overridable so tests can use a throwaway namespace.
    public let service: String

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    /// `kSecUseDataProtectionKeychain` opts every operation into the modern,
    /// app-group-scoped keychain instead of the legacy file-based one — on macOS
    /// that is what keeps these items out of the user's login keychain, where any
    /// other signed app could prompt for them.
    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func data(for key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                logger.error("keychain returned non-data for \(key, privacy: .public)")
                throw SecretStoreError.decodingFailed
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            logger.error("keychain read failed for \(key, privacy: .public): \(status)")
            throw SecretStoreError.keychain(status: status)
        }
    }

    public func set(_ data: Data, for key: String) throws {
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // ThisDeviceOnly: OAuth tokens are bound to this device's registration,
            // so syncing them to another Mac via iCloud Keychain or a backup would
            // spread a live credential for no benefit.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            logger.error("keychain update failed for \(key, privacy: .public): \(updateStatus)")
            throw SecretStoreError.keychain(status: updateStatus)
        }

        let addStatus = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            logger.error("keychain add failed for \(key, privacy: .public): \(addStatus)")
            throw SecretStoreError.keychain(status: addStatus)
        }
    }

    public func removeValue(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("keychain delete failed for \(key, privacy: .public): \(status)")
            throw SecretStoreError.keychain(status: status)
        }
    }
}
