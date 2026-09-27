import HeraldKit
import SwiftUI

/// The band above the list (handoff §3.1 "Header band"): the folder as the
/// title, then "{scope} · {folder}" and, when a label is open, its chip.
///
/// At All domains and at a domain the title IS the folder menu — the sidebar
/// there lists domains and mailboxes, not folders. At a mailbox the sidebar
/// lists the folders itself, so the same title is plain text.
struct ListHeaderBand: View {
    @Bindable var model: MailViewModel

    private var title: String { ListColumn.folderTitle(model.folder) }

    var body: some View {
        VStack(alignment: .leading, spacing: ListColumn.Layout.headerGap) {
            if ListColumn.titleIsFolderMenu(model.scope) {
                FolderMenu(model: model)
            } else {
                Text(title)
                    .textStyle(MailTheme.Typography.paneTitle)
                    .foregroundStyle(MailTheme.Color.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(AccessibilityID.MailList.title)
            }
            HStack(spacing: ListColumn.Layout.attributionGap) {
                Text(model.listCaption)
                    .textStyle(MailTheme.Typography.caption)
                    .foregroundStyle(MailTheme.Color.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier(AccessibilityID.MailList.caption)
                if ListColumn.showsLabelChip(labelOpen: model.selectedLabel != nil, folder: model.folder),
                   let label = model.selectedLabel {
                    LabelFilterChip(label: label) { model.clearLabel() }
                }
            }
            // The chip is taller than the caption; a fixed floor keeps the band
            // from jumping when a label opens or closes.
            .frame(minHeight: MailTheme.Spacing.lg + MailTheme.Spacing.xxs, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, ListColumn.Layout.headerTopPadding)
        .padding(.horizontal, ListColumn.Layout.headerHorizontalPadding)
        .padding(.bottom, ListColumn.Layout.headerBottomPadding)
    }
}

/// The header title as a real `Menu` — so it opens from the keyboard, reads as
/// a pop-up to VoiceOver and gets the system menu chrome — of the six folders,
/// each a `Toggle` (the checkmark column; the "menus carry selection with
/// Toggle rows" rule) with its symbol and, for Inbox and Drafts, a count.
struct FolderMenu: View {
    @Bindable var model: MailViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var title: String { ListColumn.folderTitle(model.folder) }

    var body: some View {
        Menu {
            ForEach(ListColumn.menuFolders, id: \.self) { folder in
                Toggle(isOn: Binding(
                    get: { model.folder == folder },
                    // Picking the current folder again is a no-op navigation;
                    // un-ticking it means nothing, so every write just selects.
                    set: { _ in model.selectFolder(folder) }
                )) {
                    Label(ListColumn.folderTitle(folder), systemImage: ListColumn.folderSymbol(folder))
                }
                // Zero draws no badge.
                .badge(model.folderMenuCount(for: folder) ?? 0)
            }
        } label: {
            HStack(spacing: MailTheme.Spacing.xxs) {
                Text(title)
                    .textStyle(MailTheme.Typography.paneTitle)
                    .foregroundStyle(MailTheme.Color.ink)
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MailTheme.Color.ink2)
            }
            .padding(.horizontal, MailTheme.Spacing.xs)
            .padding(.vertical, MailTheme.Spacing.xxs)
            .background(
                isHovering ? MailTheme.Color.lineSoft : .clear,
                in: RoundedRectangle(cornerRadius: MailTheme.Radius.badgeLarge)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        // The hover fill sits OUTSIDE the text's own edge, as in the design
        // (padding 2 4, margin −2 −4), so the title still aligns with the caption.
        .padding(.horizontal, -MailTheme.Spacing.xs)
        .padding(.vertical, -MailTheme.Spacing.xxs)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : MailTheme.Animation.micro) { isHovering = hovering }
        }
        .help("Choose a folder")
        .accessibilityLabel("Folder")
        .accessibilityValue(title)
        .accessibilityIdentifier(AccessibilityID.MailList.folderMenu)
    }
}

/// The open label, as a removable chip in the header caption: the label's
/// wash (R1 chip rule — 18% fill, 55% hairline, name in the text colour) with
/// its name and an × that clears it.
struct LabelFilterChip: View {
    let label: MailLabel
    let clear: () -> Void

    private var tint: Color { MailTheme.labelTint(for: label.color) }

    var body: some View {
        HStack(spacing: MailTheme.Spacing.xxs) {
            Text(label.name)
                .textStyle(MailTheme.Typography.chip)
                .foregroundStyle(MailTheme.chipLabelForeground)
                .lineLimit(1)
            Button(action: clear) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(MailTheme.Color.ink2)
                    // The chip is ~18pt tall; the hit area reaches 28pt without
                    // growing the chip (the padding is taken back for layout).
                    .padding(MailTheme.Spacing.sm)
                    .contentShape(Rectangle())
                    .padding(-MailTheme.Spacing.sm)
            }
            .buttonStyle(.plain)
            .help("Remove label filter")
            .accessibilityLabel("Remove label filter \(label.name)")
            .accessibilityIdentifier(AccessibilityID.MailList.clearLabel)
        }
        .padding(.leading, MailTheme.Spacing.sm)
        .padding(.trailing, MailTheme.Spacing.xs)
        .padding(.vertical, MailTheme.Spacing.xxs)
        .background(tint.opacity(MailTheme.Wash.chipFill), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(MailTheme.Wash.chipBorder)))
    }
}

/// What an empty list says (handoff §3.1 "Drafts" / "Other empty folders").
/// Drawn over the empty `List`, never inside a row, so it reads the fixed ink
/// tokens directly.
struct ListEmptyStateView: View {
    let state: ListColumn.EmptyState
    /// The Drafts-in-a-mailbox state's action; ignored unless the state offers it.
    var showAllDrafts: (() -> Void)?

    var body: some View {
        VStack(spacing: MailTheme.Spacing.sm) {
            Image(systemName: state.symbol)
                .font(MailTheme.Typography.emptyGlyph)
                .foregroundStyle(MailTheme.Color.ink3)
                .accessibilityHidden(true)
            Text(state.title)
                .textStyle(MailTheme.Typography.emptyTitle)
                .foregroundStyle(MailTheme.Color.ink)
                .accessibilityIdentifier(AccessibilityID.MailList.emptyTitle)
            if let message = state.message {
                Text(message)
                    .textStyle(MailTheme.Typography.snippet)
                    .foregroundStyle(MailTheme.Color.ink3)
            }
            if state.offersShowAllDrafts, let showAllDrafts {
                Button(ListColumn.showAllDraftsTitle, action: showAllDrafts)
                    .controlSize(.large)
                    .padding(.top, MailTheme.Spacing.xs)
                    .accessibilityIdentifier(AccessibilityID.MailList.showAllDrafts)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, MailTheme.Spacing.xxxl)
        // Sits a little above centre, like the design's (padding-bottom 60).
        .padding(.bottom, MailTheme.Spacing.xxxl * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A row's attribution (handoff §2): `[AC] sales@ ·`, `sales@ ·`, or the
/// "No mailbox" tag. Hidden from VoiceOver — the row's combined summary
/// speaks the attribution itself (`ListColumn.Attribution.spoken`).
///
/// Drawn inside `List` rows, so its text uses the HIERARCHICAL styles, which
/// flip with the system selection (the R1 List-row rule).
struct RowAttributionView: View {
    let attribution: ListColumn.Attribution
    let tint: MailTheme.AccountTint?

    var body: some View {
        HStack(spacing: ListColumn.Layout.attributionGap) {
            if attribution.isUnassigned {
                NoMailboxTag()
            } else {
                if let monogram = attribution.monogram, let tint {
                    DomainBadge(monogram: monogram, tint: tint, size: .row)
                }
                if let mailbox = attribution.mailbox {
                    Text(mailbox)
                        .textStyle(MailTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .textStyle(MailTheme.Typography.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// "No mailbox" — a draft (or an unassigned message) that no mailbox owns,
/// where a badge and a mailbox would otherwise sit. Outlined, never filled:
/// it names an absence, not an account.
struct NoMailboxTag: View {
    var body: some View {
        Text(ListColumn.noMailboxTitle)
            .textStyle(MailTheme.Typography.tag)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, MailTheme.Spacing.xs)
            .overlay {
                RoundedRectangle(cornerRadius: MailTheme.Radius.badgeSmall)
                    .strokeBorder(MailTheme.Color.line)
            }
    }
}

/// The 1px border a selected row adds under Differentiate Without Color, so
/// the selection is a shape and not only a fill. `.primary` rather than the
/// accent: inside a focused `List` the system selection fill IS the accent,
/// and an accent border on it would vanish exactly where it is needed.
struct SelectionOutline: ViewModifier {
    let isSelected: Bool
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    func body(content: Content) -> some View {
        content.overlay {
            if isSelected, differentiateWithoutColor {
                RoundedRectangle(cornerRadius: MailTheme.Radius.md)
                    .strokeBorder(.primary, lineWidth: MailTheme.selectionBorderWidth)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func selectionOutline(_ isSelected: Bool) -> some View {
        modifier(SelectionOutline(isSelected: isSelected))
    }
}
