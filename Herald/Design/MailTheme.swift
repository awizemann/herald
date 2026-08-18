import HeraldKit
import SwiftUI

/// One entry of the mailbox colour palette: the token NAME is what is persisted
/// and what VoiceOver says, the `Color` is only how it draws.
nonisolated struct MailboxTint: Sendable, Hashable, Identifiable {
    let name: String
    let color: Color

    var id: String { name }

    /// Title-cased for the swatch's accessibility label and the picker row.
    var displayName: String { name.capitalized }
}

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

    /// Folders the sidebar shows, in order.
    /// `starred` is conversation-only on the server (there is no starred *message*
    /// folder — the list is derived from `starredAt`), see `SyncFolder.starred`.
    ///
    /// Drafts is NOT here and cannot be: it is not a `ConversationFolder` at all
    /// (the conversation enum has `starred` where the message enum has `drafts`)
    /// and drafts are not messages. It is a special sidebar item — see
    /// `MailViewModel.SidebarItem` — drawn from the two tokens below.
    static let sidebarFolders: [ConversationFolder] = [.inbox, .starred, .sent, .archived, .trash]

    /// The Drafts sidebar item. Its own tokens rather than a `title(for:)` case,
    /// because there is no folder value to switch on.
    static let draftsTitle = "Drafts"
    static let draftsSymbol = "doc.text"

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

    // MARK: Search

    /// Fill behind a run of a row's text that matches the search query. The
    /// system yellow (not `.yellow`) so it shifts under dark mode and Increase
    /// Contrast, at a strength that stays readable under `.secondary` text.
    nonisolated static let searchMatchBackground = Color(nsColor: .systemYellow).opacity(0.35)

    /// Foreground of a matched run. Lifted to `.primary` because the snippet it
    /// most often sits in is drawn `.secondary`; paired with the bold weight the
    /// highlighter also applies, so the mark is never colour alone.
    nonisolated static let searchMatchForeground: Color = .primary

    // MARK: Mailbox tints

    /// The fixed mailbox palette, in assignment order. `NSColor.system*` rather
    /// than `.blue`/`.teal`: the AppKit system colours are the ones that adapt to
    /// dark mode and to Increase Contrast, which a chip drawn at 18% opacity
    /// needs badly.
    ///
    /// ORDER IS PART OF THE CONTRACT: ``MailboxColorAssignment`` indexes into it
    /// with a stable hash, so reordering repaints every mailbox that never got an
    /// explicit override.
    nonisolated static let mailboxPalette: [MailboxTint] = [
        MailboxTint(name: "blue", color: Color(nsColor: .systemBlue)),
        MailboxTint(name: "teal", color: Color(nsColor: .systemTeal)),
        MailboxTint(name: "green", color: Color(nsColor: .systemGreen)),
        MailboxTint(name: "orange", color: Color(nsColor: .systemOrange)),
        MailboxTint(name: "pink", color: Color(nsColor: .systemPink)),
        MailboxTint(name: "purple", color: Color(nsColor: .systemPurple)),
        MailboxTint(name: "indigo", color: Color(nsColor: .systemIndigo)),
        MailboxTint(name: "brown", color: Color(nsColor: .systemBrown)),
    ]

    /// The tint for a palette token name, or `nil` for a name outside the palette
    /// (a stale override written by an older build).
    nonisolated static func mailboxTint(named name: String) -> MailboxTint? {
        mailboxPalette.first { $0.name == name }
    }

    /// How strongly a mailbox chip's tint fills its background. The label is drawn
    /// in the full-strength tint on top, so the chip is never colour-only.
    nonisolated static let mailboxChipFillOpacity: Double = 0.18

    // MARK: Metrics

    /// Width of a row's trailing date slot. FIXED, and sized for the longest form
    /// ``RowDateFormatter`` produces, so neither a long mailbox name nor a long
    /// sender can squeeze the date into an ellipsis — which is exactly what the
    /// one-line layout did before.
    static let dateSlotWidth: CGFloat = 78
    /// Every list row reserves at least this height (chip/date line, sender, subject,
    /// one preview line). macOS `List` caches a row's measured height, so a row whose
    /// content grows after first layout — new mail arriving, mailbox names filling in —
    /// can otherwise stay clipped at the shorter height it was first measured with.
    /// It also feeds `defaultMinListRowHeight` on both lists — the height an
    /// unmeasured, freshly inserted row is drawn at — so it must be the FULL
    /// height of a four-line row (chip, sender, subject, two preview lines ≈ the
    /// ~71pt trailing column plus padding), not a partial one.
    static let rowMinHeight: CGFloat = 88

    /// Minimum hit target for an icon-only control (the intrinsic ~18pt glyph is
    /// too small to click reliably and fails pointer-accessibility guidance).
    static let hitTarget: CGFloat = 28

    /// Height of the sidebar's sync-status slot. FIXED and always occupied: the
    /// status used to appear and disappear, pushing the whole folder list down
    /// and back on every poll.
    static let statusSlotHeight: CGFloat = 16

    /// Diameter of the unread dot. ONE value for both the conversation row and the
    /// reading-pane message header — they drew 8pt and 7pt for the same indicator
    /// before, a drift no one chose. The rounder 8pt wins; both sites adopt it.
    static let unreadDotDiameter: CGFloat = 8

    static let minWindow = CGSize(width: 900, height: 560)

    // MARK: Spacing scale

    /// The 4pt spacing grid every stack `spacing:` and `.padding` reads from, so
    /// the whole app breathes on one rhythm instead of each call site guessing.
    /// Off-grid literals from before the grid are AUTO-SNAPPED to the nearest step
    /// (ties round up); `spacing: 0` stays a bare literal because it is structural,
    /// not rhythm. `xxs` is the lone half-step, kept only because 1–2pt insets exist.
    enum Spacing {
        /// 2pt — the half-step. Tight vertical insets and hairline stack gaps.
        static let xxs: CGFloat = 2
        /// 4pt — the base grid unit. Snug pairs (dot inset, chip vertical padding).
        static let xs: CGFloat = 4
        /// 8pt — the workhorse. Icon-to-label gaps and standard row padding.
        static let sm: CGFloat = 8
        /// 12pt — section padding and the horizontal gutter of most bars.
        static let md: CGFloat = 12
        /// 16pt — pane edges and the onboarding column's breathing room.
        static let lg: CGFloat = 16
        /// 20pt — reserved next step; no literal needs it yet.
        static let xl: CGFloat = 20
        /// 24pt — reserved next step; no literal needs it yet.
        static let xxl: CGFloat = 24
        /// 32pt — the largest inset (the onboarding card's outer padding).
        static let xxxl: CGFloat = 32
    }

    // MARK: Radius scale

    /// Corner radii for the app's rounded fills. Radii are NOT held to the spacing
    /// grid — a 6pt corner reads right on a small chip where an 8pt one would look
    /// soft — so this is its own short scale.
    enum Radius {
        /// 6pt — chips (attachment, message count) and other small pill fills.
        static let sm: CGFloat = 6
    }

    // MARK: Typography

    /// The two hero glyphs — the onboarding mark and the empty-root mark — are the
    /// only places that reach past Apple's semantic text styles for a display-size
    /// SF Symbol. Named here so weight and size travel together; everything else
    /// stays on `.headline`/`.caption`/`.body` and needs no token.
    enum Typography {
        /// 44pt light — the onboarding welcome glyph.
        static let heroGlyph = Font.system(size: 44, weight: .light)
        /// 40pt light — the empty-state glyph on the root pane.
        static let largeGlyph = Font.system(size: 40, weight: .light)
    }

    // MARK: Animation

    /// Motion tokens. The token is ONLY the `Animation` value — the reduce-motion
    /// gate stays at the call site (`reduceMotion ? nil : MailTheme.Animation.quick`)
    /// so each view keeps deciding whether it animates at all.
    enum Animation {
        /// The show/hide of the thread pane and its kin: a short, symmetric ease.
        static let quick = SwiftUI.Animation.easeInOut(duration: 0.18)
    }
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
