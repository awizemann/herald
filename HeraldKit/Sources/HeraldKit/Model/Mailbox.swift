import Foundation

/// A sending/receiving address attached to a mailbox.
/// CACHE-BLOB CONVENTION — this type is stored VERBATIM in a SwiftData column
/// (`CachedMailbox.addresses`): an opaque blob with no
/// migration hook, so every row an older build wrote is decoded by today's code.
///
/// SwiftData decodes such a column with `try!` (verified: a missing key faults in
/// `DefaultStore.swift`), so a shape change is NOT a recoverable error — it is a
/// hard crash inside the fetch, repeated on every launch, until the store file is
/// deleted. That is why `init(from:)` below is TOTAL: every field is defaulted
/// and no missing, renamed or retyped key can make decoding throw.
///
/// A new field is therefore added in THREE places — the property, `CodingKeys`,
/// and the decode below — and must have a sensible default. Defaulting is safe
/// precisely because this is a cache: the next fetch from the server corrects it.
public nonisolated struct MailboxAddress: Sendable, Hashable, Codable, Identifiable {
    // Listed explicitly: see the cache-blob convention above.
    enum CodingKeys: String, CodingKey {
        case id, mailboxID, mailDomainID, address, displayName, receiveEnabled, sendEnabled, isPrimary
    }

    /// Total decode — a throw here would be a `try!` crash inside SwiftData.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)).flatMap { $0 } ?? fallback
        }
        self.id = value(.id, "")
        self.mailboxID = value(.mailboxID, "")
        self.mailDomainID = value(.mailDomainID, "")
        self.address = value(.address, "")
        self.displayName = value(.displayName, "")
        self.receiveEnabled = value(.receiveEnabled, false)
        self.sendEnabled = value(.sendEnabled, false)
        self.isPrimary = value(.isPrimary, false)
    }

    public let id: String
    public let mailboxID: String
    public let mailDomainID: String
    public let address: String
    public let displayName: String
    public let receiveEnabled: Bool
    public let sendEnabled: Bool
    public let isPrimary: Bool

    public init(
        id: String,
        mailboxID: String,
        mailDomainID: String,
        address: String,
        displayName: String,
        receiveEnabled: Bool,
        sendEnabled: Bool,
        isPrimary: Bool
    ) {
        self.id = id
        self.mailboxID = mailboxID
        self.mailDomainID = mailDomainID
        self.address = address
        self.displayName = displayName
        self.receiveEnabled = receiveEnabled
        self.sendEnabled = sendEnabled
        self.isPrimary = isPrimary
    }
}

/// A shared mailbox the authenticated user can access.
public nonisolated struct Mailbox: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let address: String
    public let addresses: [MailboxAddress]
    public let displayName: String
    public let isActive: Bool
    /// `nil` when the server did not report an access level for this caller.
    public let accessLevel: MailboxAccessLevel?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        address: String,
        addresses: [MailboxAddress],
        displayName: String,
        isActive: Bool,
        accessLevel: MailboxAccessLevel?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.address = address
        self.addresses = addresses
        self.displayName = displayName
        self.isActive = isActive
        self.accessLevel = accessLevel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Addresses this mailbox may send from, primary first.
    public var sendableAddresses: [MailboxAddress] {
        addresses.filter(\.sendEnabled).sorted { lhs, rhs in
            lhs.isPrimary && !rhs.isPrimary
        }
    }
}
