import HeraldKit
import SwiftUI

/// One label, drawn as a tinted pill.
///
/// The same rule as ``MailboxChip``: the NAME is always drawn and the colour is a
/// second cue on top of it, never the label itself — so the chip survives
/// greyscale, Increase Contrast and a reader who cannot tell teal from green.
/// VoiceOver reads labels from the row's combined summary, hence the hidden flag.
///
/// The name is drawn in ``MailTheme/chipLabelForeground`` and the tint carries the
/// FILL and the border only: a caption2 name in systemYellow/orange/teal over an
/// 18% wash of the same tint misses AA in light mode.
struct LabelChip: View {
    let label: MailLabel

    private var tint: Color { MailTheme.labelTint(for: label.color) }

    var body: some View {
        Text(label.name)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(MailTheme.chipLabelForeground)
            .lineLimit(1)
            .padding(.horizontal, MailTheme.Spacing.xs)
            .padding(.vertical, MailTheme.Spacing.xxs)
            .background(tint.opacity(MailTheme.mailboxChipFillOpacity), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(MailTheme.chipBorderOpacity)))
            .accessibilityHidden(true)
    }
}

/// A row's labels: the first few as chips, the remainder as a count.
///
/// Renders NOTHING when there are no labels — not an empty `HStack` with its
/// spacing, which would still cost the row a line of height on every unlabelled
/// message (which is most of them).
struct LabelChipRow: View {
    let labels: [MailLabel]
    var limit: Int = MailTheme.maxRowLabelChips

    var body: some View {
        if !labels.isEmpty {
            HStack(spacing: MailTheme.Spacing.xs) {
                ForEach(labels.prefix(limit)) { label in
                    LabelChip(label: label)
                }
                if labels.count > limit {
                    Text("+\(labels.count - limit)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, MailTheme.Spacing.xs)
                        .padding(.vertical, MailTheme.Spacing.xxs)
                        .background(MailTheme.chipBackground, in: Capsule())
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }
            // The chips are decorative here; the names ride in the row's own
            // accessibility summary so VoiceOver reads them in one breath.
            .accessibilityHidden(true)
        }
    }

    /// What VoiceOver says for a set of labels, or `nil` when there are none.
    /// Pure and static so it is assertable without a rendered row.
    nonisolated static func accessibilityPhrase(for labels: [MailLabel]) -> String? {
        guard !labels.isEmpty else { return nil }
        return "labelled " + labels.map(\.name).joined(separator: ", ")
    }
}
