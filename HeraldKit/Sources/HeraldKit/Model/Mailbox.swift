import Foundation

/// A sending/receiving address attached to a mailbox.
public nonisolated struct MailboxAddress: Sendable, Hashable, Codable, Identifiable {
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
