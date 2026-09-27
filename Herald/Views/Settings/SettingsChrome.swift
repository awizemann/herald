import SwiftUI

// The Settings window's shared chrome (handoff §3.2): the page frame
// (breadcrumb + serif title), section headers, grouped cards and their rows,
// the SERVER / HERALD source tags and the outline button. Every Settings page —
// the root pages here and the domain pages R8/R9 build — is assembled from
// these, so the window keeps one look.

/// Structural sizes of the Settings window. Frames, not spacing — so bare
/// numbers rather than `MailTheme.Spacing` steps (the token convention).
enum SettingsLayout {
    static let defaultSize = CGSize(width: 1000, height: 680)
    static let minSize = CGSize(width: 820, height: 520)
    static let sidebarWidth: CGFloat = 240
    /// A page's content never runs wider than this, however wide the window.
    static let contentMaxWidth: CGFloat = 720
    /// Space between a page's blocks (title, each section).
    static let pageSpacing: CGFloat = 22
    static let pageHorizontalPadding: CGFloat = 40
    /// A density preview's frame, and the ring that marks the chosen one.
    static let previewRingWidth: CGFloat = 2
    /// An account-colour swatch: 18pt drawn, with a 2pt surface gap and an ink
    /// ring around the chosen one.
    static let swatchDiameter: CGFloat = 18
    static let swatchGap: CGFloat = 2
    static let swatchRingWidth: CGFloat = 1.5
    static let avatarDiameter: CGFloat = 28
    static let sidebarBadgeSize: CGFloat = 18
    static let headerBadgeSize: CGFloat = 24
    /// A domain badge inside a list row (the density previews).
    static let rowBadgeHeight: CGFloat = 16
    static let rowHeight: CGFloat = 30
}

/// One page of the detail pane: breadcrumb caption, serif title, then the
/// page's sections, left-aligned in a column no wider than 720.
///
/// `scrolls: false` is for a page whose content scrolls itself (the Signatures
/// list is a grouped `Form`) — nesting it in a second scroll view would give it
/// no height to scroll in.
struct SettingsPage<Content: View>: View {
    let title: String
    let breadcrumb: String
    var scrolls = true
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if scrolls {
                ScrollView {
                    column { content }
                }
            } else {
                column { content.frame(maxHeight: .infinity, alignment: .top) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MailTheme.Color.surface)
    }

    private func column<Inner: View>(@ViewBuilder _ inner: () -> Inner) -> some View {
        VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
            VStack(alignment: .leading, spacing: MailTheme.Spacing.xs) {
                Text(breadcrumb)
                    .textStyle(MailTheme.Typography.caption)
                    .foregroundStyle(MailTheme.Color.ink3)
                    .accessibilityLabel(breadcrumb.replacingOccurrences(of: " › ", with: ", "))
                Text(title)
                    .textStyle(MailTheme.Typography.title)
                    .foregroundStyle(MailTheme.Color.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(AccessibilityID.Settings.pageTitle)
            }
            inner()
        }
        .frame(maxWidth: SettingsLayout.contentMaxWidth, alignment: .leading)
        .padding(.top, MailTheme.Spacing.xs)
        .padding(.horizontal, SettingsLayout.pageHorizontalPadding)
        .padding(.bottom, MailTheme.Spacing.xxxl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A titled block: the uppercase section caption ("SERVER", "ON THIS MAC")
/// over its content. `title: nil` for a card with no caption (sign-out).
struct SettingsSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: MailTheme.Spacing.sm) {
            if let title {
                Text(title)
                    .textStyle(MailTheme.Typography.section)
                    .foregroundStyle(MailTheme.Color.ink3)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
    }
}

/// A grouped card: 1px `line` border, radius lg, each child a row separated
/// from the next by a `lineSoft` hairline.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    row
                    if index < rows.count - 1 {
                        Rectangle()
                            .fill(MailTheme.Color.lineSoft)
                            .frame(height: 1)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .background(MailTheme.Color.surface, in: RoundedRectangle(cornerRadius: MailTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: MailTheme.Radius.lg)
                .strokeBorder(MailTheme.Color.line, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

/// One card row: title (and an optional note under it) on the left, the
/// row's control and its source tag on the right. Padding 12 × 16.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var note: String?
    var source: SettingsSource?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: MailTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: MailTheme.Spacing.xxs) {
                Text(title)
                    .textStyle(MailTheme.Typography.body)
                    .foregroundStyle(MailTheme.Color.ink)
                if let note {
                    Text(note)
                        .textStyle(MailTheme.Typography.caption)
                        .foregroundStyle(MailTheme.Color.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
            if let source { SettingsSourceTag(source: source) }
        }
        .padding(.vertical, MailTheme.Spacing.md)
        .padding(.horizontal, MailTheme.Spacing.lg)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(title: String, note: String? = nil, source: SettingsSource? = nil) {
        self.init(title: title, note: note, source: source) { EmptyView() }
    }
}

/// Where a setting lives — what the tag beside it says.
enum SettingsSource: Equatable {
    /// Read from the HQBase API; Herald shows it, the server owns it.
    case server
    /// A Herald preference, stored on this Mac only.
    case herald

    var text: String {
        switch self {
        case .server: "SERVER"
        case .herald: "HERALD"
        }
    }

    /// What VoiceOver says instead of the shouted caps.
    var accessibilityLabel: String {
        switch self {
        case .server: "From the server"
        case .herald: "Herald setting, this Mac only"
        }
    }
}

/// The SERVER (ink3 on a `line` outline) / HERALD (accent on a half-strength
/// accent outline) tag. Mono 9, never colour alone: the word is the cue.
struct SettingsSourceTag: View {
    let source: SettingsSource

    var body: some View {
        Text(source.text)
            .textStyle(MailTheme.Typography.tag)
            .foregroundStyle(foreground)
            .padding(.vertical, MailTheme.Spacing.xxs)
            .padding(.horizontal, MailTheme.Spacing.xs + MailTheme.Spacing.xxs)
            .overlay {
                RoundedRectangle(cornerRadius: MailTheme.Radius.badgeSmall)
                    .strokeBorder(border, lineWidth: 1)
            }
            .fixedSize()
            .help(source.accessibilityLabel)
            .accessibilityLabel(source.accessibilityLabel)
    }

    private var foreground: Color {
        source == .server ? MailTheme.Color.ink3 : MailTheme.Color.accent
    }

    private var border: Color {
        source == .server ? MailTheme.Color.line : MailTheme.Color.accent.opacity(0.5)
    }
}

/// The handoff's outline button: 28pt high, 12pt sides, a `line` outline at
/// radius sm; `isDestructive` draws the title in `danger` (Sign Out…).
struct SettingsOutlineButtonStyle: ButtonStyle {
    var isDestructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textStyle(MailTheme.Typography.bodyMedium)
            .foregroundStyle(isDestructive ? MailTheme.Color.danger : MailTheme.Color.ink)
            .padding(.horizontal, MailTheme.Spacing.md)
            .frame(minHeight: MailTheme.hitTarget)
            .background(
                configuration.isPressed ? MailTheme.Color.lineSoft : MailTheme.Color.surface,
                in: RoundedRectangle(cornerRadius: MailTheme.Radius.sm)
            )
            .overlay {
                RoundedRectangle(cornerRadius: MailTheme.Radius.sm)
                    .strokeBorder(MailTheme.Color.line, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: MailTheme.Radius.sm))
            .opacity(isEnabled ? 1 : 0.5)
            .fixedSize()
    }
}

/// A domain's monogram tile in the account's tint wash: 22% fill + a 60% 1px
/// inner border, mono letters in `ink`. Always drawn beside the domain name, so
/// it is hidden from VoiceOver.
///
/// NOTE: a minimal Settings-local badge. Phase R6 may add a shared
/// `Herald/Design/DomainBadge.swift`; when both land, this one folds into it.
struct SettingsDomainBadge: View {
    let monogram: String
    let tint: MailTheme.AccountTint
    var size: CGFloat = SettingsLayout.sidebarBadgeSize

    var body: some View {
        let isHeader = size >= SettingsLayout.headerBadgeSize
        let radius = isHeader ? MailTheme.Radius.badgeLarge : MailTheme.Radius.badgeMedium
        // Mono 10 at header size, 9 in a sidebar row (handoff: badges 9–10).
        Text(monogram)
            .font(isHeader ? MailTheme.Typography.badge.font : MailTheme.Typography.tag.font)
            .foregroundStyle(MailTheme.Color.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: size, height: size)
            .background(tint.solid.opacity(MailTheme.Wash.badgeFill), in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(tint.solid.opacity(MailTheme.Wash.badgeBorder), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

/// The account's avatar: a solid tint disc with the account's initial in the
/// tint's matching dark text colour.
struct SettingsAccountAvatar: View {
    let label: String
    let tint: MailTheme.AccountTint
    var diameter: CGFloat = SettingsLayout.avatarDiameter

    var body: some View {
        Text(label.first.map { String($0).uppercased() } ?? "?")
            .font(MailTheme.Typography.headline.font)
            .foregroundStyle(tint.avatarText)
            .frame(width: diameter, height: diameter)
            .background(tint.solid, in: Circle())
            .accessibilityHidden(true)
    }
}
