import AppKit
import Foundation
import HeraldKit

/// The middle column's pure rules (redesign R5): which attribution a row shows
/// at each scope, what the header, caption, search prompt and empty states say,
/// the folder menu's order and counts, the density metrics, and the thread
/// header's "N messages · M people".
///
/// Pure and `nonisolated`, like `ReadingPaneMessagePosition`: every rule the
/// list column draws is assertable without a rendered view. The view-model
/// bridge (`MailViewModel+ListColumn.swift`) feeds it the live state; the views
/// only draw what comes back.
nonisolated enum ListColumn {
    // MARK: - Attribution (handoff §2)

    /// Which levels of "where did this come from" a row shows: only the ones
    /// the current scope has not already fixed.
    enum AttributionLevel: Equatable, Sendable {
        /// All domains: domain badge + mailbox local part (`[AC] sales@`).
        case domainAndMailbox
        /// One domain: the mailbox local part only (`sales@`).
        case mailbox
        /// One mailbox: nothing — every row would say the same thing.
        case none

        init(scope: MailViewModel.Scope) {
            switch scope {
            case .allDomains: self = .domainAndMailbox
            case .domain: self = .mailbox
            case .mailbox: self = .none
            }
        }
    }

    /// What one row's attribution draws. All `nil`/`false` = nothing.
    struct Attribution: Equatable, Sendable {
        /// The domain badge's monogram, or `nil` for no badge.
        var monogram: String?
        /// The mailbox's local part with its `@` (`"sales@"`), or `nil`.
        var mailbox: String?
        /// A row with no mailbox at all (a draft not tied to one, an
        /// unassigned catch-all message): the "No mailbox" tag instead of a
        /// badge and a mailbox.
        var isUnassigned = false
        /// What VoiceOver reads for it — the full address, since "sales at"
        /// alone says less than the badge beside it does on screen.
        var spoken: String?

        static let none = Attribution()

        var isEmpty: Bool { monogram == nil && mailbox == nil && !isUnassigned }
    }

    /// Everything a list needs to attribute its rows, resolved ONCE per list
    /// pass rather than per row: the domain monograms need the whole account's
    /// domains (a clash promotes both to three letters), which is a scan per
    /// domain, not something to repeat for every row on screen.
    struct AttributionIndex: Sendable {
        let level: AttributionLevel
        let monograms: [Mailbox.ID: String]
        let localParts: [Mailbox.ID: String]
        let addresses: [Mailbox.ID: String]

        static let empty = AttributionIndex(level: .none, monograms: [:], localParts: [:], addresses: [:])

        /// - Parameters:
        ///   - monogramOverrides: the user's per-domain monogram (Settings ›
        ///     Domain › Overview), already read out of `UserDefaults`.
        ///   - accountID: only used to satisfy the badge resolver; the tint
        ///     itself is drawn from the list column's own account-tint helper.
        static func make(
            level: AttributionLevel,
            mailboxes: [Mailbox],
            domains: [MailDomain],
            monogramOverrides: [MailDomain.ID: String],
            accountID: String
        ) -> AttributionIndex {
            guard level != .none else { return .empty }
            var monograms: [Mailbox.ID: String] = [:]
            if level == .domainAndMailbox {
                // One resolve per DOMAIN (its first mailbox stands in for all
                // of them), fanned out to every mailbox it holds.
                for domain in domains {
                    guard let first = domain.mailboxIDs.first,
                          let info = DomainBadgeResolver.resolve(
                              mailboxID: first, domains: domains, monogramOverrides: monogramOverrides,
                              accountID: accountID, tintOverride: nil
                          )
                    else { continue }
                    for id in domain.mailboxIDs { monograms[id] = info.monogram }
                }
            }
            var localParts: [Mailbox.ID: String] = [:]
            var addresses: [Mailbox.ID: String] = [:]
            for mailbox in mailboxes {
                localParts[mailbox.id] = ListColumn.localPart(of: mailbox.address)
                addresses[mailbox.id] = mailbox.address
            }
            return AttributionIndex(level: level, monograms: monograms, localParts: localParts, addresses: addresses)
        }

        /// A row's attribution by its mailbox id.
        ///
        /// A row with NO mailbox shows the "No mailbox" tag wherever
        /// attribution shows at all — in practice only All domains, the one
        /// scope that lists such rows. A mailbox this index does not know yet
        /// (the mailbox list is a moment behind a new row) shows nothing rather
        /// than a wrong or half-drawn attribution; the next mailbox reload
        /// fills it in.
        func attribution(forMailbox mailboxID: String?) -> Attribution {
            guard level != .none else { return .none }
            guard let mailboxID else {
                return Attribution(isUnassigned: true, spoken: ListColumn.noMailboxTitle)
            }
            guard let local = localParts[mailboxID] else { return .none }
            return Attribution(
                monogram: level == .domainAndMailbox ? monograms[mailboxID] : nil,
                mailbox: local,
                spoken: addresses[mailboxID]
            )
        }
    }

    static let noMailboxTitle = "No mailbox"

    /// `"sales@acme.co"` → `"sales@"`. An address without an `@` (never from a
    /// real server; a fully defaulted cache row) is shown whole.
    static func localPart(of address: String) -> String {
        guard let at = address.lastIndex(of: "@") else { return address }
        return String(address[...at])
    }

    // MARK: - Header, caption, search

    /// The scope as the header caption and the search prompt name it.
    static func scopeName(_ scope: MailViewModel.Scope, domains: [MailDomain], mailboxes: [Mailbox]) -> String {
        switch scope {
        case .allDomains:
            return "All domains"
        case .domain(let id):
            return domains.first { $0.id == id }?.name ?? "Domain"
        case .mailbox(let id):
            return mailboxes.first { $0.id == id }?.address ?? "Mailbox"
        }
    }

    /// The toolbar search field's placeholder — it names what a search covers.
    static func searchPrompt(_ scope: MailViewModel.Scope, scopeName: String) -> String {
        if case .allDomains = scope { return "Search all domains" }
        return "Search \(scopeName)"
    }

    static func folderTitle(_ folder: MailViewModel.Folder) -> String {
        folder.conversationFolder.map(MailTheme.title(for:)) ?? MailTheme.draftsTitle
    }

    static func folderSymbol(_ folder: MailViewModel.Folder) -> String {
        folder.conversationFolder.map(MailTheme.symbol(for:)) ?? MailTheme.draftsSymbol
    }

    /// "{scope} · {folder}" — "All domains · Sent", "sales@acme.co · Drafts".
    static func caption(scopeName: String, folder: MailViewModel.Folder) -> String {
        "\(scopeName) · \(folderTitle(folder))"
    }

    /// Levels 1–2 (All domains, a domain) title the list with a folder MENU;
    /// at a mailbox the sidebar already lists the folders, so the title is
    /// plain text there.
    static func titleIsFolderMenu(_ scope: MailViewModel.Scope) -> Bool {
        if case .mailbox = scope { return false }
        return true
    }

    /// Whether the caption carries the open label's chip. Not behind Drafts:
    /// a label does not narrow the drafts list (drafts carry no label Herald
    /// can read), so a chip there would claim a filter that is not applied.
    static func showsLabelChip(labelOpen: Bool, folder: MailViewModel.Folder) -> Bool {
        labelOpen && folder != .drafts
    }

    /// The folder menu's rows, in the sidebar's order with Drafts after Sent.
    static let menuFolders: [MailViewModel.Folder] = [
        .inbox, .conversation(.starred), .conversation(.sent), .drafts,
        .conversation(.archived), .conversation(.trash),
    ]

    /// The count beside a folder menu row: Inbox unread and the Drafts total
    /// for the current scope, nothing for the rest (and nothing at zero).
    static func menuCount(
        for folder: MailViewModel.Folder,
        unreadByFolder: [ConversationFolder: Int],
        draftCount: Int
    ) -> Int? {
        let count: Int
        switch folder {
        case .conversation(.inbox): count = unreadByFolder[.inbox] ?? 0
        case .drafts: count = draftCount
        default: return nil
        }
        return count > 0 ? count : nil
    }

    // MARK: - Empty states

    struct EmptyState: Equatable, Sendable {
        let symbol: String
        let title: String
        let message: String?
        /// The Drafts-in-a-mailbox state's "Show All Drafts" button.
        let offersShowAllDrafts: Bool
    }

    static let showAllDraftsTitle = "Show All Drafts"

    /// What an empty list says.
    ///
    /// - Parameters:
    ///   - searching: a search is filtering the list — "No Results" wins
    ///     whatever the folder.
    ///   - serverSearchPending: the server has not been asked yet, so Return
    ///     is worth suggesting (it promises nothing that is already on its way).
    static func emptyState(
        folder: MailViewModel.Folder,
        scope: MailViewModel.Scope,
        scopeName: String,
        labelName: String?,
        searching: Bool,
        serverSearchPending: Bool
    ) -> EmptyState {
        if searching, folder != .drafts {
            return EmptyState(
                symbol: "magnifyingglass",
                title: "No Results",
                message: serverSearchPending ? "Press Return to search the server." : nil,
                offersShowAllDrafts: false
            )
        }
        if folder == .drafts, case .mailbox = scope {
            return EmptyState(
                symbol: MailTheme.draftsSymbol,
                title: "No drafts in \(localPart(of: scopeName))",
                message: "Drafts that aren’t tied to a mailbox are listed under All domains › Drafts.",
                offersShowAllDrafts: true
            )
        }
        let message = if let labelName, folder != .drafts {
            "No conversations labelled \(labelName) here."
        } else {
            "in \(scopeName)"
        }
        return EmptyState(
            symbol: folderSymbol(folder),
            title: "Nothing in \(folderTitle(folder))",
            message: message,
            offersShowAllDrafts: false
        )
    }

    // MARK: - Density

    /// The row metrics a density setting implies (handoff §1 density table).
    struct RowMetrics: Equatable, Sendable {
        let verticalPadding: CGFloat
        let snippetLines: Int
        /// Compact folds the subject onto the attribution + sender line.
        let subjectInline: Bool

        init(_ density: ListDensity) {
            switch density {
            case .comfortable:
                verticalPadding = Layout.comfortableRowPadding
                snippetLines = 2
                subjectInline = false
            case .compact:
                verticalPadding = Layout.compactRowPadding
                snippetLines = 1
                subjectInline = true
            }
        }

        /// The height of a full row without label chips — the floor both for
        /// the row itself and for the `List`'s unmeasured-row height (see
        /// "Herald Design System and Accessibility", list row heights: a
        /// freshly inserted row is drawn at `defaultMinListRowHeight` before
        /// its own layout is ever consulted, so the floor must BE a full row).
        func conversationRowHeight(_ lines: LineHeights) -> CGFloat {
            let first = max(lines.body, Layout.badgeRowHeight)
            var height = 2 * verticalPadding + first + Layout.lineGap + lines.snippet(lines: snippetLines)
            if !subjectInline { height += Layout.lineGap + lines.body }
            return height.rounded(.up)
        }

        /// A drilled-in thread's message row: sender, "To:", snippet, beside a
        /// 28pt avatar.
        func messageRowHeight(_ lines: LineHeights) -> CGFloat {
            let text = lines.body + Layout.messageLineGap + lines.caption
                + Layout.messageLineGap + lines.snippet(lines: snippetLines)
            return (2 * verticalPadding + max(text, Layout.avatarDiameter)).rounded(.up)
        }
    }

    /// One-line heights of the list's text styles, as SwiftUI lays them out.
    struct LineHeights: Equatable, Sendable {
        let body: CGFloat
        let caption: CGFloat
        let snippetLine: CGFloat
        /// Extra space `.textStyle(.snippet)` puts between wrapped lines.
        let snippetLineSpacing: CGFloat

        func snippet(lines: Int) -> CGFloat {
            CGFloat(lines) * snippetLine + CGFloat(max(0, lines - 1)) * snippetLineSpacing
        }

        /// Measured from the bundled faces (or the system fallback) — the same
        /// natural line the `Typography.Style` line-spacing conversion uses.
        static let current = LineHeights(
            body: naturalLine(MailTheme.Typography.body),
            caption: naturalLine(MailTheme.Typography.caption),
            snippetLine: naturalLine(MailTheme.Typography.snippet),
            snippetLineSpacing: MailTheme.Typography.snippet.lineSpacing
        )

        static func naturalLine(_ style: MailTheme.Typography.Style) -> CGFloat {
            let font = MailTheme.Typography.usesBundledFonts ? NSFont(name: style.face.rawValue, size: style.size) : nil
            return font.map { $0.ascender - $0.descender + $0.leading } ?? style.size * 1.2
        }
    }

    /// The handoff's list-column geometry (§3.1). Named here rather than
    /// forced onto the 4pt grid: several are deliberately off it (14, 7, 10,
    /// 3), and the design is high fidelity for row anatomy. The on-grid ones
    /// (20, 12, 2) equal `MailTheme.Spacing.xl/md/xxs`, spelled as literals
    /// only because `MailTheme.Spacing` is main-actor isolated and this enum
    /// is not.
    enum Layout {
        static let headerTopPadding: CGFloat = 14
        static let headerHorizontalPadding: CGFloat = 20
        static let headerBottomPadding: CGFloat = 10
        static let headerGap: CGFloat = 5
        static let comfortableRowPadding: CGFloat = 14
        static let compactRowPadding: CGFloat = 7
        static let rowHorizontalPadding: CGFloat = 12
        /// Between the dot column, the text column and the trailing column.
        static let rowColumnGap: CGFloat = 10
        /// The dot's column is 10 wide; the dot itself is 8.
        static let dotColumnWidth: CGFloat = 10
        static let lineGap: CGFloat = 3
        static let messageLineGap: CGFloat = 2
        /// Inside line 1: badge, mailbox, "·", sender.
        static let attributionGap: CGFloat = 6
        static let badgeRowHeight: CGFloat = 16
        static let avatarDiameter: CGFloat = 28
        /// The ring the thread row's unread dot draws against the avatar.
        static let dotRingWidth: CGFloat = 2
        static let threadBackTopPadding: CGFloat = 12
        static let threadBackHorizontalPadding: CGFloat = 14
        static let threadHeaderTopPadding: CGFloat = 6
        static let threadHeaderBottomPadding: CGFloat = 14
        static let threadHeaderGap: CGFloat = 6
    }

    // MARK: - Thread

    /// "5 messages · 3 people" — people are the distinct SENDERS, compared by
    /// bare address and case-insensitively, so one person writing from
    /// "Ada <ada@x>" and "ada@x" counts once.
    static func threadSummary(_ messages: [MessageSummary]) -> String {
        let count = messages.count
        let people = participantCount(messages)
        let messagesText = count == 1 ? "1 message" : "\(count) messages"
        let peopleText = people == 1 ? "1 person" : "\(people) people"
        return "\(messagesText) · \(peopleText)"
    }

    static func participantCount(_ messages: [MessageSummary]) -> Int {
        Set(messages.map { bareAddress($0.fromAddress).lowercased() }.filter { !$0.isEmpty }).count
    }

    /// `"Ada Lovelace <ada@example.com>"` → `"ada@example.com"`; a bare address
    /// comes back trimmed.
    static func bareAddress(_ from: String) -> String {
        let trimmed = from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.lastIndex(of: "<"), trimmed.hasSuffix(">") else { return trimmed }
        return String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
            .trimmingCharacters(in: .whitespaces)
    }

    /// What a row shows as the sender: the display name when the From header
    /// carries one (`"Ada Lovelace" <ada@x>` → `Ada Lovelace`), else the
    /// address. The same parse the new-mail notifier uses for its title.
    static func senderName(_ from: String) -> String {
        let trimmed = from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.lastIndex(of: "<"), trimmed.hasSuffix(">") else { return trimmed }
        let name = trimmed[trimmed.startIndex..<open]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return name.isEmpty ? bareAddress(trimmed) : name
    }

    /// Two initials for a 28pt avatar: "Jonas Weber" → "JW"; a bare address
    /// uses its local part ("ops@north.io" → "OP").
    static func initials(_ from: String) -> String {
        let name = senderName(from)
        if name.contains("@") || !name.contains(" ") {
            let base = name.split(separator: "@").first.map(String.init) ?? name
            return String(base.prefix(2)).uppercased()
        }
        let letters = name.split(separator: " ").compactMap(\.first).prefix(2)
        return String(letters).uppercased()
    }

    /// Whether a message is the user's OWN — sent by Herald's side (outbound)
    /// or from one of the account's mailbox addresses. Its avatar takes the
    /// account tint; everyone else's stays neutral.
    ///
    /// - Parameter ownAddresses: lowercased bare addresses.
    static func isOwnMessage(_ message: MessageSummary, ownAddresses: Set<String>) -> Bool {
        message.direction == .outbound || ownAddresses.contains(bareAddress(message.fromAddress).lowercased())
    }
}
