import Foundation

/// Something that stores small secrets (tokens, OAuth client registrations) by key.
///
/// `nonisolated` so actors — and the in-memory fake used by tests — can conform
/// under default-MainActor isolation.
public nonisolated protocol SecretStore: Sendable {
    func data(for key: String) throws -> Data?
    func set(_ data: Data, for key: String) throws
    func removeValue(for key: String) throws
}

extension SecretStore {
    /// Reads and JSON-decodes a stored value; returns `nil` when nothing is stored.
    public func value<T: Decodable>(_ type: T.Type = T.self, for key: String) throws -> T? {
        guard let data = try data(for: key) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SecretStoreError.decodingFailed
        }
    }

    /// JSON-encodes and stores a value.
    public func setValue(_ value: some Encodable, for key: String) throws {
        do {
            try set(JSONEncoder().encode(value), for: key)
        } catch is EncodingError {
            throw SecretStoreError.encodingFailed
        }
    }

    public func string(for key: String) throws -> String? {
        guard let data = try data(for: key) else { return nil }
        guard let string = String(data: data, encoding: .utf8) else { throw SecretStoreError.decodingFailed }
        return string
    }

    public func setString(_ string: String, for key: String) throws {
        try set(Data(string.utf8), for: key)
    }
}

/// Errors a ``SecretStore`` can raise. Never carries the secret itself.
public nonisolated enum SecretStoreError: Error, Sendable, Hashable {
    /// A `SecItem*` call failed; payload is the `OSStatus`.
    case keychain(status: Int32)
    case decodingFailed
    case encodingFailed
}
