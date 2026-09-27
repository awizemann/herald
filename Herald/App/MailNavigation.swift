import Foundation
import HeraldKit

extension MailViewModel {
    /// Which mail the list is drawn from — the sidebar's axis. Independent of
    /// ``Folder`` and of the open label: changing one never resets the others.
    nonisolated enum Scope: Hashable, Sendable {
        /// Every mailbox of the account, minus the domains the user hid or took
        /// out of "All domains" (``DomainPreferences``).
        case allDomains
        /// Every mailbox of one domain, by ``MailDomain/id``.
        case domain(MailDomain.ID)
        /// One mailbox.
        case mailbox(Mailbox.ID)
    }

    /// Which folder the list shows — the second axis.
    ///
    /// Drafts is NOT a ``ConversationFolder``: the server has no drafts
    /// conversation folder (the conversation enum swaps `drafts` for `starred`),
    /// drafts are not messages, and `GET /messages?folder=drafts` is dead. So it
    /// is its own case here rather than a member of the conversation enum, and
    /// everything that only makes sense for conversations reads
    /// ``conversationFolder``, which is `nil` for it.
    nonisolated enum Folder: Hashable, Sendable {
        case conversation(ConversationFolder)
        case drafts

        static let inbox = Folder.conversation(.inbox)

        /// The conversation folder, or `nil` for Drafts.
        var conversationFolder: ConversationFolder? {
            if case .conversation(let folder) = self { return folder }
            return nil
        }
    }

    /// Where the middle column is looking: scope ∩ folder ∩ label.
    ///
    /// One value rather than three stored properties, so every navigation is a
    /// single assignment the view-model can compare, persist and report as one
    /// step — and a reload that captured it can tell, after its await, whether
    /// ANY of the three moved underneath it.
    nonisolated struct Location: Hashable, Sendable {
        var scope: Scope
        var folder: Folder
        /// The open label, or `nil`. It narrows the folder listing (label ∩
        /// folder), it does not replace it — and it does not narrow Drafts,
        /// which carry no label Herald can read (see the label caching note).
        var labelID: String?

        static let launchDefault = Location(scope: .allDomains, folder: .inbox, labelID: nil)
    }
}

// MARK: - Persistence

/// Per-account persistence of ``MailViewModel/Location`` — scope, folder and
/// label, nothing view-level — so relaunch comes back to where the user was.
///
/// A value-type API over an injected `UserDefaults`, like ``DomainPreferences``.
/// Encoded as plain strings rather than `Codable` data so the keys stay
/// readable in `defaults read` and a malformed value degrades to the default
/// instead of failing a decode.
nonisolated enum NavigationPersistence {
    /// The key the pre-redesign sidebar stored its picked mailbox under (`""` =
    /// All mailboxes). Read once, migrated, then removed.
    static func legacyMailboxKey(accountID: String) -> String { "sidebar.mailbox.\(accountID)" }
    static func scopeKey(accountID: String) -> String { "sidebar.scope.\(accountID)" }
    static func folderKey(accountID: String) -> String { "sidebar.folder.\(accountID)" }
    static func labelKey(accountID: String) -> String { "sidebar.label.\(accountID)" }

    /// The stored location, migrating the legacy mailbox key on first read.
    ///
    /// Nothing here checks that the scope's domain/mailbox or the label still
    /// exist — that needs the mailbox and label lists, which only the
    /// view-model has; it falls back when it knows (see
    /// `MailViewModel.validatedLocation(_:)`).
    static func load(accountID: String, from defaults: UserDefaults) -> MailViewModel.Location {
        migrateLegacyMailbox(accountID: accountID, in: defaults)
        var location = MailViewModel.Location.launchDefault
        if let raw = defaults.string(forKey: scopeKey(accountID: accountID)), let scope = scope(from: raw) {
            location.scope = scope
        }
        if let raw = defaults.string(forKey: folderKey(accountID: accountID)), let folder = folder(from: raw) {
            location.folder = folder
        }
        if let raw = defaults.string(forKey: labelKey(accountID: accountID)), !raw.isEmpty {
            location.labelID = raw
        }
        return location
    }

    static func save(_ location: MailViewModel.Location, accountID: String, to defaults: UserDefaults) {
        defaults.set(raw(for: location.scope), forKey: scopeKey(accountID: accountID))
        defaults.set(raw(for: location.folder), forKey: folderKey(accountID: accountID))
        if let labelID = location.labelID {
            defaults.set(labelID, forKey: labelKey(accountID: accountID))
        } else {
            defaults.removeObject(forKey: labelKey(accountID: accountID))
        }
    }

    /// One-time: the old picked mailbox becomes a `.mailbox` scope (`""` → All
    /// domains), and the old key is removed so this never runs twice. A scope
    /// the new code already stored wins — the legacy key is then just dropped.
    private static func migrateLegacyMailbox(accountID: String, in defaults: UserDefaults) {
        let legacyKey = legacyMailboxKey(accountID: accountID)
        guard let legacy = defaults.string(forKey: legacyKey) else { return }
        defaults.removeObject(forKey: legacyKey)
        guard defaults.string(forKey: scopeKey(accountID: accountID)) == nil else { return }
        let scope: MailViewModel.Scope = legacy.isEmpty ? .allDomains : .mailbox(legacy)
        defaults.set(raw(for: scope), forKey: scopeKey(accountID: accountID))
    }

    // MARK: Encoding

    private static let domainPrefix = "domain:"
    private static let mailboxPrefix = "mailbox:"
    private static let allDomainsRaw = "all"

    /// Ids are appended after a fixed prefix and read back as "everything after
    /// it", so an id that itself contains `:` (``MailDomain``'s fallback ids do)
    /// round-trips.
    static func raw(for scope: MailViewModel.Scope) -> String {
        switch scope {
        case .allDomains: allDomainsRaw
        case .domain(let id): domainPrefix + id
        case .mailbox(let id): mailboxPrefix + id
        }
    }

    static func scope(from raw: String) -> MailViewModel.Scope? {
        if raw == allDomainsRaw { return .allDomains }
        if raw.hasPrefix(domainPrefix), raw.count > domainPrefix.count {
            return .domain(String(raw.dropFirst(domainPrefix.count)))
        }
        if raw.hasPrefix(mailboxPrefix), raw.count > mailboxPrefix.count {
            return .mailbox(String(raw.dropFirst(mailboxPrefix.count)))
        }
        return nil
    }

    private static let draftsRaw = "drafts"

    static func raw(for folder: MailViewModel.Folder) -> String {
        switch folder {
        case .conversation(let folder): folder.rawValue
        case .drafts: draftsRaw
        }
    }

    static func folder(from raw: String) -> MailViewModel.Folder? {
        if raw == draftsRaw { return .drafts }
        return ConversationFolder(rawValue: raw).map(MailViewModel.Folder.conversation)
    }
}
