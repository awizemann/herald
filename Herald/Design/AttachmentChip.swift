import SwiftUI

/// One attachment, as a chip.
///
/// The reading pane and the composer drew two near-identical HStacks that had
/// drifted apart (different paddings, different shapes, only one of them an
/// accessibility element). One component, two trailing controls.
struct AttachmentChip<Trailing: View>: View {
    let filename: String
    /// `nil` for a draft attachment whose size is not interesting to the user.
    var sizeBytes: Int?
    /// The chip's action button (save, or remove).
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: MailTheme.Spacing.sm) {
            Image(systemName: "doc").accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(filename)
                    .font(.caption)
                    .lineLimit(1)
                if let sizeBytes {
                    Text(sizeBytes.formatted(.byteCount(style: .file)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            trailing
        }
        .padding(.horizontal, MailTheme.Spacing.sm)
        .padding(.vertical, MailTheme.Spacing.xs)
        .background(MailTheme.chipBackground, in: RoundedRectangle(cornerRadius: MailTheme.Radius.sm))
        // One element per attachment: VoiceOver reads "invoice.pdf, 88 KB" and
        // then offers the button, instead of three unrelated stops.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var label: String {
        guard let sizeBytes else { return filename }
        return "\(filename), \(sizeBytes.formatted(.byteCount(style: .file)))"
    }
}
