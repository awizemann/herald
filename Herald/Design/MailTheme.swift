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

    /// Folders the P0 sidebar shows, in order. Drafts arrives with the composer.
    static let sidebarFolders: [ConversationFolder] = [.inbox, .sent, .archived, .trash]

    // MARK: Status

    static let unreadIndicator = Color.accentColor
    static let starred = Color.yellow
    static let syncing = Color.secondary
    static let failure = Color.red

    // MARK: Metrics

    /// Minimum hit target for an icon-only control (the intrinsic ~18pt glyph is
    /// too small to click reliably and fails pointer-accessibility guidance).
    static let hitTarget: CGFloat = 28
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
