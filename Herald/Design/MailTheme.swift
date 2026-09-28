import AppKit
import HeraldKit
import SwiftUI

/// The single source for folder symbols, colour tokens, type and the few
/// shared metrics. Views never hardcode an SF Symbol name, a colour or a font.
enum MailTheme {
    // MARK: Folders

    nonisolated static func symbol(for folder: ConversationFolder) -> String {
        switch folder {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .starred: "star"
        case .archived: "archivebox"
        case .trash: "trash"
        case .catchall: "tray.2"
        }
    }

    nonisolated static func title(for folder: ConversationFolder) -> String {
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
    /// `MailViewModel.Folder.drafts` — drawn from the two tokens below.
    static let sidebarFolders: [ConversationFolder] = [.inbox, .starred, .sent, .archived, .trash]

    /// The Drafts sidebar item. Its own tokens rather than a `title(for:)` case,
    /// because there is no folder value to switch on.
    nonisolated static let draftsTitle = "Drafts"
    nonisolated static let draftsSymbol = Symbol.drafts

    // MARK: Symbols

    /// The SF Symbol map (handoff §5), one name per ROLE. Views spell a role,
    /// never a symbol string, so a role that changes glyph changes everywhere.
    /// Folder glyphs go through ``symbol(for:)``; these are the rest.
    nonisolated enum Symbol {
        static let drafts = "doc.text"
        static let allDomains = "tray.2"
        static let mailbox = "at"
        static let label = "tag"
        static let newMessage = "square.and.pencil"
        static let refresh = "arrow.clockwise"
        static let reply = "arrowshape.turn.up.left"
        static let replyAll = "arrowshape.turn.up.left.2"
        static let forward = "arrowshape.turn.up.right"
        static let attachment = "paperclip"
        static let sessionLock = "lock.fill"
        /// Warning glyph — always the FILLED triangle (§5), inline errors too.
        static let warning = "exclamationmark.triangle.fill"
        static let remoteImages = "photo"
        static let drillDown = "chevron.right"
        static let back = "chevron.left"
        static let accountSwitcher = "chevron.up.chevron.down"
        static let domainSettings = "gearshape"
        static let receiveSendOn = "checkmark.circle.fill"
        static let receiveSendOff = "nosign"
        static let hiddenDomain = "eye.slash"
        static let openAdmin = "arrow.up.right.square"
        static let folderMenu = "chevron.down"
        static let currentItem = "checkmark"
        static let clearLabelFilter = "xmark.circle.fill"
        static let quickLook = "eye"
        static let download = "arrow.down.circle"
        static let downloadAll = "arrow.down.circle"
        static let removeAttachment = "xmark"
        static let archive = "archivebox"
        static let trash = "trash"
        static let send = "paperplane.fill"
        static let nothingSelected = "envelope.open"
        static let noResults = "magnifyingglass"
    }

    // MARK: Colour tokens

    /// The redesign's colour tokens (handoff §1). Each is a colour set in
    /// `Assets.xcassets/Theme` with Any + Dark appearances; the tokens that carry
    /// text or boundaries (line, lineSoft, ink2, ink3, accent, danger) also have
    /// Increase Contrast variants. Appearance and contrast therefore switch in
    /// the asset catalogue, never at a call site.
    ///
    /// Named `Color` to sit beside `Spacing`/`Radius`/`Animation`, so inside
    /// `MailTheme` the SwiftUI type is spelled `SwiftUI.Color`.
    ///
    /// Looked up by NAME, not through the generated `ColorResource` symbols: those
    /// are main-actor isolated under default-MainActor, and these tokens must be
    /// `nonisolated` (the search highlighter and the label chips' nonisolated
    /// helpers read them). `ThemeTokenTests` resolves every name, so a typo or a
    /// renamed colour set fails a test instead of drawing clear.
    nonisolated enum Color {
        /// List column / window canvas.
        static let bg = SwiftUI.Color("bg")
        /// Sidebar fill for a non-`List` surface (the source list draws its own).
        static let sidebar = SwiftUI.Color("sidebar")
        /// Reading pane, settings detail, cards, fields.
        static let surface = SwiftUI.Color("surface")
        /// Borders and field outlines.
        static let line = SwiftUI.Color("line")
        /// Row separators, hover fill, neutral chip fill.
        static let lineSoft = SwiftUI.Color("lineSoft")
        /// Primary text.
        static let ink = SwiftUI.Color("ink")
        /// Secondary text (snippets, "To:").
        static let ink2 = SwiftUI.Color("ink2")
        /// Tertiary / meta text (dates, counts, captions, section headers).
        static let ink3 = SwiftUI.Color("ink3")
        /// Unread dot, primary button, selected icon, focus ring.
        static let accent = SwiftUI.Color("accent")
        /// Text and glyphs drawn ON `accent`.
        static let onAccent = SwiftUI.Color("onAccent")
        /// Selected conversation/message row fill on a non-`List` surface. The
        /// sidebar keeps the system source-list selection.
        static let select = SwiftUI.Color("select")
        /// The starred glyph.
        static let star = SwiftUI.Color("star")
        /// Failure and destructive actions.
        static let danger = SwiftUI.Color("danger")
        /// Success. Dark resolves to `systemGreen`, as the handoff asks.
        static let ok = SwiftUI.Color("ok")
        /// Warning banner, info glyph.
        static let warn = SwiftUI.Color("warn")
        /// Search-match highlight fill.
        static let match = SwiftUI.Color("match")
    }

    // MARK: Status

    static let unreadIndicator = Color.accent
    static let starred = Color.star
    /// The sidebar's sync-status line is meta text, so `ink3`.
    static let syncing = Color.ink3
    /// `danger`, whose Increase Contrast variant keeps the property `systemRed`
    /// was chosen for: legible on the `.bar` material the banners and the
    /// sidebar status line are drawn on, at any contrast setting.
    static let failure = Color.danger

    // MARK: Surfaces

    /// Background of a neutral chip (attachment, message count) — the design's
    /// neutral chip fill. One token, so every chip in the app moves together.
    /// Fixed and opaque, so NOT for a chip on a selected `List` row — see
    /// ``rowChipBackground(isSelected:)``.
    static let chipBackground: AnyShapeStyle = AnyShapeStyle(Color.lineSoft)

    /// The neutral chip fill for a chip drawn INSIDE a `List` row (the count
    /// pill, the "+n" label overflow). Unselected it is ``chipBackground``; on
    /// a selected row it turns hierarchical (`.quaternary`), which flips with
    /// the selection like the chip's `.secondary` text does — the opaque
    /// `lineSoft` stayed near-white under white text on the accent fill.
    static func rowChipBackground(isSelected: Bool) -> AnyShapeStyle {
        isSelected ? AnyShapeStyle(.quaternary) : chipBackground
    }

    /// Fill behind a selected row in a list that is not a `List`.
    static let selectionHighlight = Color.select

    /// Border width for that selection when the user asked for shape as well as
    /// colour (Differentiate Without Color).
    static let selectionBorderWidth: CGFloat = 1

    // Text drawn INSIDE `List` rows (conversation, draft, thread-message and
    // sidebar rows) uses the HIERARCHICAL styles — `.primary` / `.secondary` /
    // `.tertiary` for the ink / ink2 / ink3 roles — never the fixed ink tokens:
    // only the system styles flip to the emphasised (white) variant on a
    // selected row, and a fixed ink would stay dark on the blue selection.
    // Surfaces outside a `List` (the list header band, empty states, the
    // thread header) read `Color.ink*` directly.
    //
    // Anything else FIXED in a row must swap on `isSelected` too: the unread
    // dot and the thread avatar's dot (accent → `.primary`, the avatar's
    // background ring dropped), a draft's red "Draft", the domain badge's
    // letters (`ink` → `.primary`, ``DomainBadge/isSelected``), the "No
    // mailbox" tag's `line` outline, and neutral chip fills
    // (``rowChipBackground(isSelected:)``). The one exception is a run that
    // brings its OWN opaque fill — a search match — which keeps a fixed ink on
    // it (see ``searchMatchForeground``).

    // MARK: Search

    /// Fill behind a run of a row's text that matches the search query — the
    /// design's `match` token, which carries its own dark value.
    nonisolated static let searchMatchBackground: SwiftUI.Color = Color.match

    /// Foreground of a matched run: the fixed `ink`, lifted above the
    /// `.secondary` snippet it most often sits in and paired with the bold
    /// weight the highlighter also applies, so the mark is never colour alone.
    ///
    /// Deliberately NOT hierarchical, unlike the rest of a `List` row: the run
    /// carries its own OPAQUE `match` fill, which does not change on a selected
    /// row, so a `.primary` that flipped to white there would sit white on pale
    /// yellow. `ink` on `match` clears AA in both appearances (each token has
    /// its own dark value), selected or not.
    nonisolated static let searchMatchForeground: SwiftUI.Color = Color.ink

    // MARK: Account tints

    /// One of the eight account tints (handoff §1): the token NAME is what is
    /// persisted and what VoiceOver says, the colours are only how it draws. All
    /// eight share one lightness and chroma, so no account reads louder than
    /// another; they are the same in both appearances.
    nonisolated struct AccountTint: Sendable, Hashable, Identifiable {
        let name: String
        /// The solid avatar fill, and the base of every wash.
        let solid: SwiftUI.Color
        /// The initial drawn ON `solid` — a dark shade of the same hue.
        let avatarText: SwiftUI.Color

        var id: String { name }

        /// Title-cased for a swatch's accessibility label.
        var displayName: String { name.capitalized }
    }

    /// The account tints, in assignment order.
    ///
    /// ORDER IS A PERSISTENCE CONTRACT: the account-tint assignment hashes an
    /// account id to an INDEX here (and stores overrides by NAME), so reordering
    /// repaints every account that has no override. Append, never reorder.
    nonisolated static let accountTints: [AccountTint] = [
        AccountTint(name: "clay", solid: SwiftUI.Color("tintClay"), avatarText: SwiftUI.Color("tintClayText")),
        AccountTint(name: "ochre", solid: SwiftUI.Color("tintOchre"), avatarText: SwiftUI.Color("tintOchreText")),
        AccountTint(name: "moss", solid: SwiftUI.Color("tintMoss"), avatarText: SwiftUI.Color("tintMossText")),
        AccountTint(name: "sage", solid: SwiftUI.Color("tintSage"), avatarText: SwiftUI.Color("tintSageText")),
        AccountTint(name: "slate", solid: SwiftUI.Color("tintSlate"), avatarText: SwiftUI.Color("tintSlateText")),
        AccountTint(name: "dusk", solid: SwiftUI.Color("tintDusk"), avatarText: SwiftUI.Color("tintDuskText")),
        AccountTint(name: "plum", solid: SwiftUI.Color("tintPlum"), avatarText: SwiftUI.Color("tintPlumText")),
        AccountTint(name: "rose", solid: SwiftUI.Color("tintRose"), avatarText: SwiftUI.Color("tintRoseText")),
    ]

    /// The tint for a token name, or `nil` for a name outside the set (a stale
    /// override written by another build). Names are lowercase; exact match.
    nonisolated static func accountTint(named name: String) -> AccountTint? {
        accountTints.first { $0.name == name }
    }

    /// Strengths for a tint drawn as a wash. A wash ALWAYS pairs its fill with a
    /// hairline border in the same tint — never colour alone.
    nonisolated enum Wash {
        /// Domain badge: 22% fill + a 60% 1px inner border.
        static let badgeFill: Double = 0.22
        static let badgeBorder: Double = 0.60
        /// Chips (labels, attribution): 18% fill + a 55% hairline — the top of
        /// the handoff's 16–18% / 50–55% range, which is what chips drew already.
        static let chipFill: Double = 0.18
        static let chipBorder: Double = 0.55
        /// A hidden domain's badge in the Hidden Domains list (handoff §3.2
        /// "Remove domain"): the same badge, dimmed as a whole rather than
        /// re-tuned fill/border numbers.
        static let hiddenBadgeOpacity: Double = 0.6
    }

    // MARK: Chips

    /// The colour a tinted chip's NAME is drawn in.
    ///
    /// `.primary` (the design's `ink` role), deliberately NOT the chip's own
    /// tint: a caption name drawn in a mid-lightness tint over an 18% wash of the
    /// same tint fails WCAG AA. The tint stays on the fill and the border, where
    /// it is a second cue on top of readable text — the chip rule. Hierarchical
    /// for the `List`-row reason given under Surfaces.
    nonisolated static let chipLabelForeground: SwiftUI.Color = .primary

    // MARK: Label colours

    /// The label palette, keyed by the SERVER's colour name.
    ///
    /// Unlike ``accountTints`` this is not an assignment order Herald owns: the
    /// ten names are the server's closed `labelColors` set, so this is a
    /// translation table, not a policy. The values are the handoff's (the same
    /// lightness and chroma as the account tints), one per name, identical in
    /// both appearances — the chip's `ink` name and hairline carry legibility.
    nonisolated static func labelTint(for color: LabelColor) -> SwiftUI.Color {
        switch color {
        case .gray: SwiftUI.Color("labelGray")
        case .red: SwiftUI.Color("labelRed")
        case .orange: SwiftUI.Color("labelOrange")
        case .amber: SwiftUI.Color("labelAmber")
        case .green: SwiftUI.Color("labelGreen")
        case .teal: SwiftUI.Color("labelTeal")
        case .blue: SwiftUI.Color("labelBlue")
        case .indigo: SwiftUI.Color("labelIndigo")
        case .purple: SwiftUI.Color("labelPurple")
        case .pink: SwiftUI.Color("labelPink")
        }
    }

    /// The sidebar's Labels section header and its row symbol.
    static let labelsSectionTitle = "Labels"
    static let labelSymbol = Symbol.label

    /// How many label chips a conversation row draws before it collapses the rest
    /// into a "+n" chip. A row that carries six labels must not push the sender
    /// and the subject off their lines.
    static let maxRowLabelChips = 3

    // MARK: Metrics

    // A list row's minimum height is per DENSITY now (redesign R5):
    // `ListColumn.RowMetrics.conversationRowHeight` / `messageRowHeight`, which
    // also feed each list's `defaultMinListRowHeight`.

    /// Minimum hit target for an icon-only control (the intrinsic ~18pt glyph is
    /// too small to click reliably and fails pointer-accessibility guidance).
    static let hitTarget: CGFloat = 28

    /// An icon-only button's frame (handoff §1 "Hit target"): 30 wide × 28
    /// tall — the 28pt minimum, a touch wider so adjacent glyphs don't crowd.
    static let iconButtonSize = CGSize(width: 30, height: 28)

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

    /// Corner radii for the app's rounded fills (handoff §1). Radii are NOT held
    /// to the spacing grid — a 5pt corner reads right on a small fill where an
    /// 8pt one would look soft — so this is its own short scale.
    enum Radius {
        /// 5pt — rows, sidebar items, buttons, small chips and tiles.
        static let sm: CGFloat = 5
        /// 7pt — fields, row selection, the account card.
        static let md: CGFloat = 7
        /// 10pt — cards, windows, sheets.
        static let lg: CGFloat = 10
        /// Fully rounded (chips). Larger than any chip is tall, so it clamps to a
        /// capsule; prefer `Capsule()` where a shape, not a radius, is wanted.
        static let pill: CGFloat = 999

        /// 4pt — a domain badge on a conversation row (16pt tall).
        static let badgeSmall: CGFloat = 4
        /// 5pt — a domain badge in the sidebar (18pt tall).
        static let badgeMedium: CGFloat = 5
        /// 6pt — a domain badge in a header (22–24pt tall).
        static let badgeLarge: CGFloat = 6
    }

    // MARK: Typography

    /// The type scale (handoff §1 "Type"): Source Serif 4 for display, Geist for
    /// text, Geist Mono for meta — bundled OFL fonts in `Herald/Fonts`,
    /// registered at launch by `ATSApplicationFontsPath` in Info.plist.
    ///
    /// Every style is built through ``font(_:size:relativeTo:)``, the ONE place
    /// that decides between the bundled faces and the system fonts
    /// (``usesBundledFonts``). Line height, tracking and case are part of a
    /// style, so views apply a whole style with `.textStyle(_:)`, not `.font`.
    nonisolated enum Typography {
        /// The central switch. `false` draws every style in the system font
        /// (serif / default / monospaced designs at the same sizes and weights) —
        /// the fallback if the bundled faces ever misbehave. The reading pane's
        /// web font follows it too (``MailTheme/Web``).
        static let usesBundledFonts = true

        /// The bundled faces, by PostScript name. `FontRegistrationTests` asserts
        /// each resolves inside the app, so a missing or renamed file fails a
        /// test instead of silently drawing the system font.
        nonisolated enum Face: String, CaseIterable, Sendable {
            /// Source Serif 4's display optical size, for the 34pt display style.
            case serifDisplay = "SourceSerif4Display-Semibold"
            /// Source Serif 4's subhead optical size, for 18–30pt titles.
            case serifSubhead = "SourceSerif4Subhead-Semibold"
            case text = "Geist-Regular"
            case textMedium = "Geist-Medium"
            case textSemibold = "Geist-SemiBold"
            case mono = "GeistMono-Regular"
            case monoSemibold = "GeistMono-SemiBold"

            /// What the system fallback draws for this face.
            var fallbackWeight: Font.Weight {
                switch self {
                case .serifDisplay, .serifSubhead, .textSemibold, .monoSemibold: .semibold
                case .textMedium: .medium
                case .text, .mono: .regular
                }
            }

            var fallbackDesign: Font.Design {
                switch self {
                case .serifDisplay, .serifSubhead: .serif
                case .mono, .monoSemibold: .monospaced
                case .text, .textMedium, .textSemibold: .default
                }
            }
        }

        /// The one font constructor every style goes through.
        static func font(_ face: Face, size: CGFloat, relativeTo textStyle: Font.TextStyle) -> Font {
            usesBundledFonts
                ? .custom(face.rawValue, size: size, relativeTo: textStyle)
                : .system(size: size, weight: face.fallbackWeight, design: face.fallbackDesign)
        }

        /// A complete text style: the font plus the line height, tracking and
        /// case the handoff specifies with it.
        nonisolated struct Style: Sendable {
            let face: Face
            let size: CGFloat
            let textStyle: Font.TextStyle
            /// CSS-style line height as a multiple of `size`; `nil` = the font's own.
            let lineHeight: CGFloat?
            /// Letter spacing as a fraction of `size` (−0.015 = −1.5%).
            let tracking: CGFloat
            let uppercased: Bool
            /// Extra leading that turns the font's natural line into `lineHeight`,
            /// for `.lineSpacing(_:)`. SwiftUI's `lineSpacing` ADDS to the natural
            /// line (ascender − descender + leading), so the CSS multiple is
            /// converted against the real face once, here, not on every render.
            let lineSpacing: CGFloat

            init(
                _ face: Face, size: CGFloat, relativeTo textStyle: Font.TextStyle,
                lineHeight: CGFloat? = nil, tracking: CGFloat = 0, uppercased: Bool = false
            ) {
                self.face = face
                self.size = size
                self.textStyle = textStyle
                self.lineHeight = lineHeight
                self.tracking = tracking
                self.uppercased = uppercased
                if let lineHeight {
                    let nsFont = usesBundledFonts ? NSFont(name: face.rawValue, size: size) : nil
                    let natural = nsFont.map { $0.ascender - $0.descender + $0.leading } ?? size * 1.2
                    lineSpacing = max(0, lineHeight * size - natural)
                } else {
                    lineSpacing = 0
                }
            }

            var font: Font { Typography.font(face, size: size, relativeTo: textStyle) }

            /// Tracking in points, for `.tracking(_:)`.
            var trackingPoints: CGFloat { tracking * size }
        }

        /// 34 / 1.1, −1.5% — the onboarding title.
        static let display = Style(.serifDisplay, size: 34, relativeTo: .largeTitle, lineHeight: 1.1, tracking: -0.015)
        /// 27 / 1.15, −1.5% — the reading-pane subject and settings page title
        /// (the handoff gives 26–28).
        static let title = Style(.serifSubhead, size: 27, relativeTo: .title, lineHeight: 1.15, tracking: -0.015)
        /// 22 / 1.0, −1% — the list column title ("All domains", "Inbox").
        static let paneTitle = Style(.serifSubhead, size: 22, relativeTo: .title2, lineHeight: 1.0, tracking: -0.01)
        /// 20 / 1.2 — the thread header subject.
        static let threadTitle = Style(.serifSubhead, size: 20, relativeTo: .title3, lineHeight: 1.2)
        /// 13 semibold — an unread sender, the selected sidebar item.
        static let headline = Style(.textSemibold, size: 13, relativeTo: .headline)
        /// 13 / 1.45 — rows and sidebar items.
        static let body = Style(.text, size: 13, relativeTo: .body, lineHeight: 1.45)
        /// 13 / 1.45 medium — the 500 end of the body range.
        static let bodyMedium = Style(.textMedium, size: 13, relativeTo: .body, lineHeight: 1.45)
        /// 14 / 1.6 — message body text. The reading pane itself is a web view;
        /// its CSS mirrors this through ``MailTheme/Web``.
        static let reading = Style(.text, size: 14, relativeTo: .body, lineHeight: 1.6)
        /// 12 / 1.4 — a row's preview line (drawn in `ink2`).
        static let snippet = Style(.text, size: 12, relativeTo: .callout, lineHeight: 1.4)
        /// 11 — sub-lines and notes (drawn in `ink3`).
        static let caption = Style(.text, size: 11, relativeTo: .subheadline)
        /// 11 semibold, +6%, uppercase — "DOMAINS", "LABELS" (drawn in `ink3`).
        static let section = Style(.textSemibold, size: 11, relativeTo: .subheadline, tracking: 0.06, uppercased: true)
        /// Mono 11 — dates, ⌘ shortcuts, SERVER/HERALD tags.
        static let meta = Style(.mono, size: 11, relativeTo: .subheadline)
        /// Mono 11 semibold — unread counts.
        static let metaStrong = Style(.monoSemibold, size: 11, relativeTo: .subheadline)
        /// Mono 10 semibold — a domain badge's letters (header/sidebar size).
        static let badge = Style(.monoSemibold, size: 10, relativeTo: .caption)
        /// Mono 9 semibold, +5% — the SERVER / HERALD source tags in Settings.
        static let sourceTag = Style(.monoSemibold, size: 9, relativeTo: .caption2, tracking: 0.05)
        /// Mono 10 — a row's message-count pill.
        static let count = Style(.mono, size: 10, relativeTo: .caption)
        /// Geist 10 — a small outlined tag ("No mailbox").
        static let tag = Style(.text, size: 10, relativeTo: .caption)
        /// Geist 11 medium — the name on the list header's label-filter chip.
        static let chip = Style(.textMedium, size: 11, relativeTo: .subheadline)
        /// Serif 18 — a list empty state's title ("Nothing in Sent").
        static let emptyTitle = Style(.serifSubhead, size: 18, relativeTo: .title3)
        /// 14 semibold — the sidebar's level-2 domain header (handoff: 14/600).
        static let sidebarHeader = Style(.textSemibold, size: 14, relativeTo: .headline)
        /// 11 semibold — a thread row's 28pt avatar initials.
        static let avatarInitials = Style(.textSemibold, size: 11, relativeTo: .caption)

        // System-font sizes the handoff does not restyle: small SF Symbols
        // sized against the text beside them, and a few bars that predate the
        // type scale. Named so no view spells `.caption` itself; moving one onto
        // the bundled scale is a deliberate size change, made here.

        /// An inline glyph at caption size — a row's paperclip, a chip's ×.
        static let inlineGlyph = Font.caption
        /// The list header's folder-menu chevron.
        static let menuChevronGlyph = Font.body.weight(.semibold)
        /// A back link's chevron (the thread view's "‹ Inbox").
        static let backChevronGlyph = Font.body.weight(.medium)
        /// A row label chip's name and the "+n" overflow chip beside it.
        static let rowChip = Font.caption2
        /// The server-search status bar under the list.
        static let statusBar = Font.caption
        /// The sidebar's sync status when it reports a problem: bold, because
        /// caption-sized `danger` on the sidebar material misses 4.5:1 at
        /// regular weight.
        static let statusProblem = Font.caption.bold()

        /// 44pt light — the onboarding welcome glyph (an SF Symbol, so system).
        static let heroGlyph = Font.system(size: 44, weight: .light)
        /// 40pt light — the empty-state glyph on the root pane.
        static let largeGlyph = Font.system(size: 40, weight: .light)
        /// 34pt thin — a list empty state's glyph (handoff: weight 200).
        static let emptyGlyph = Font.system(size: 34, weight: .thin)
    }

    // MARK: Web (reading pane)

    /// The reading pane is a `WKWebView`, so its colours cannot be SwiftUI
    /// `Color`s — they have to be literal CSS. They still belong to the design
    /// system, so they live here as the one source, mirrored into CSS custom
    /// properties by the document wrapper, rather than being spelled inline in a
    /// stylesheet string.
    ///
    /// Values are the sRGB hex of the colour tokens above (ink / ink2 / surface /
    /// accent, and accent + the Slate and Sage account tints for the quote-level
    /// bars) in each appearance; `ThemeTokenTests` pins them to the asset
    /// catalogue so the two cannot drift. They are deliberately CONSERVATIVE:
    /// only unstyled regions of a message pick them up. Herald never inverts a
    /// sender's own colours.
    enum Web {
        nonisolated struct Palette: Sendable {
            let foreground: String
            let secondary: String
            let background: String
            let link: String
            /// Border colours for nesting levels 1, 2 and 3 of a blockquote.
            let quoteBars: [String]
            /// Very light wash behind a quoted block, distinct per level.
            let quoteSurface: String
            /// `secondary` and `link` under System Settings → Accessibility →
            /// Increase Contrast (`prefers-contrast: more`) — the ink2 / accent
            /// Increase Contrast variants. Only these two: the base palette
            /// already clears AA, and the rest of the pane is the sender's own
            /// colours, which Herald does not touch at any contrast setting.
            let secondaryIncreasedContrast: String
            let linkIncreasedContrast: String
        }

        nonisolated static let light = Palette(
            foreground: "#13161c",
            secondary: "#4e535a",
            background: "#ffffff",
            link: "#2e62c9",
            quoteBars: ["#2e62c9", "#37a1b8", "#55a57d"],
            quoteSurface: "rgba(127,127,127,0.06)",
            secondaryIncreasedContrast: "#363a40",
            linkIncreasedContrast: "#1c47a3"
        )

        nonisolated static let dark = Palette(
            foreground: "#eef0f3",
            secondary: "#a7abb1",
            background: "#191b1e",
            link: "#73a3fc",
            quoteBars: ["#73a3fc", "#37a1b8", "#55a57d"],
            quoteSurface: "rgba(127,127,127,0.12)",
            secondaryIncreasedContrast: "#cdd0d5",
            linkIncreasedContrast: "#a3c3ff"
        )

        /// The reading type: 14 / 1.6 (``Typography/reading``).
        nonisolated static let readingFontSize = 14
        nonisolated static let readingLineHeight = 1.6

        /// The font stack for message text. Geist first ONLY when
        /// ``fontFaceRule`` actually embeds it; the system stack is always there
        /// behind it.
        nonisolated static var readingFontStack: String {
            let system = "-apple-system, system-ui, sans-serif"
            return fontFaceRule.isEmpty ? system : "\"Geist\", \(system)"
        }

        /// An `@font-face` rule carrying the Geist variable font as a `data:`
        /// URL, or "" when bundled fonts are off or the file is missing.
        ///
        /// Why a data URL: the web content process cannot see fonts the app
        /// registered, and any URL that points at the bundle would need a file
        /// read-access grant or a loosened policy. The document's CSP already
        /// allows `font-src data:` (and nothing else), and the content rule list
        /// only blocks network schemes — so embedding the font changes neither.
        /// One variable file (~70 KB) covers every weight; italics are synthesised.
        /// Built once per process.
        nonisolated static let fontFaceRule: String = {
            guard Typography.usesBundledFonts,
                  let url = Bundle.main.url(forResource: "Geist-Variable", withExtension: "woff2"),
                  let data = try? Data(contentsOf: url)
            else { return "" }
            return """
            @font-face { font-family: "Geist"; font-style: normal; font-weight: 100 900; \
            src: url(data:font/woff2;base64,\(data.base64EncodedString())) format("woff2"); }
            """
        }()
    }

    // MARK: Animation

    /// Motion tokens. The token is ONLY the `Animation` value — the reduce-motion
    /// gate stays at the call site (`reduceMotion ? nil : MailTheme.Animation.quick`)
    /// so each view keeps deciding whether it animates at all (reduced motion
    /// becomes a 0 ms cross-fade there).
    enum Animation {
        /// 120 ms ease-out — hover, press, star.
        static let micro = SwiftUI.Animation.easeOut(duration: 0.12)
        /// 180 ms ease-in-out — the list ↔ thread swap, banners.
        static let quick = SwiftUI.Animation.easeInOut(duration: 0.18)
        /// 220 ms ease-in-out — a sidebar level change (the rows cross-fade).
        static let scope = SwiftUI.Animation.easeInOut(duration: 0.22)
        /// 260 ms spring, damping 0.9 — sheets, the account popover.
        static let settle = SwiftUI.Animation.spring(response: 0.26, dampingFraction: 0.9)
    }
}

extension View {
    /// Standard treatment for an icon-only button: real hit target, help tag and
    /// accessibility label always travel together.
    func iconButtonStyle(_ label: String) -> some View {
        frame(width: MailTheme.iconButtonSize.width, height: MailTheme.iconButtonSize.height)
            .contentShape(Rectangle())
            .help(label)
            .accessibilityLabel(label)
    }

    /// Applies a whole ``MailTheme/Typography/Style`` — font, tracking, line
    /// height and case — so none of them is forgotten at a call site.
    func textStyle(_ style: MailTheme.Typography.Style) -> some View {
        font(style.font)
            .tracking(style.trackingPoints)
            .lineSpacing(style.lineSpacing)
            .textCase(style.uppercased ? .uppercase : nil)
    }
}
