import HeraldKit
import SwiftUI

/// The single source for folder symbols, status colors and the few shared
/// metrics. Views never hardcode an SF Symbol name or a status color.
enum MailTheme {
    // MARK: Folders

    static func symbol(for folder: ConversationFolder) -> String {
        switch folder {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .starred: "star"
        case .archived: "archivebox"
        case .trash: "trash"
        case .catchall: "tray.2"
        }
    }

    static func title(for folder: ConversationFolder) -> String {
        switch folder {
        case .inbox: "Inbox"
        case .sent: "Sent"
        case .starred: "Starred"
        case .archived: "Archived"
        case .trash: "Trash"
        case .catchall: "Catch-all"
        }
    }

    /// Folders the sidebar shows, in order. Drafts arrives with the composer.
    /// `starred` is conversation-only on the server (there is no starred *message*
    /// folder — the list is derived from `starredAt`), see `SyncFolder.starred`.
    static let sidebarFolders: [ConversationFolder] = [.inbox, .starred, .sent, .archived, .trash]

    // MARK: Status

    static let unreadIndicator = Color.accentColor
    static let starred = Color.yellow
    static let syncing = Color.secondary
    /// `systemRed`, not `.red`: the AppKit system color is the one that shifts
    /// under Increase Contrast and stays legible on the `.bar` material the
    /// banners and the sidebar status line are drawn on.
    static let failure = Color(nsColor: .systemRed)

    // MARK: Surfaces

    /// Background of a chip (attachment, message count). One token, so every chip
    /// in the app moves together instead of each spelling `.quaternary`.
    static let chipBackground: AnyShapeStyle = AnyShapeStyle(.quaternary)

    /// Fill behind a selected row in a list that is not a `List` — the thread
    /// message picker draws its own selection.
    static let selectionHighlight = Color.accentColor.opacity(0.12)

    /// Border width for that selection when the user asked for shape as well as
    /// colour (Differentiate Without Color).
    static let selectionBorderWidth: CGFloat = 1

    /// Foreground for the mailbox attribution chip on a row in the "All
    /// Mailboxes" scope. A token, not `.secondary` spelled inline, and paired
    /// with the chip background so the chip is never colour-only.
    static let attributionForeground: Color = .secondary

    // MARK: Metrics

    /// Minimum hit target for an icon-only control (the intrinsic ~18pt glyph is
    /// too small to click reliably and fails pointer-accessibility guidance).
    static let hitTarget: CGFloat = 28

    /// Height of the sidebar's sync-status slot. FIXED and always occupied: the
    /// status used to appear and disappear, pushing the whole folder list down
    /// and back on every poll.
    static let statusSlotHeight: CGFloat = 16

    static let minWindow = CGSize(width: 900, height: 560)
}

extension View {
    /// Standard treatment for an icon-only button: real hit target, help tag and
    /// accessibility label always travel together.
    func iconButtonStyle(_ label: String) -> some View {
        frame(width: MailTheme.hitTarget, height: MailTheme.hitTarget)
            .contentShape(Rectangle())
            .help(label)
            .accessibilityLabel(label)
    }
}
