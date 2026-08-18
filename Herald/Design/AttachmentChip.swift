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
    /// An upload still on its way up: the leading glyph becomes a spinner and the
    /// chip dims, so a finished attachment is never mistaken for one in flight.
    var isInFlight = false
    /// The chip's action button (save, or remove).
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: MailTheme.Spacing.sm) {
            if isInFlight {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            } else {
                Image(systemName: "doc").accessibilityHidden(true)
            }
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
        .opacity(isInFlight ? 0.6 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        // The spinner is decorative; the STATE is what VoiceOver needs, and it has
        // to be spoken, not just animated.
        .accessibilityValue(isInFlight ? "Uploading" : "")
    }

    private var label: String {
        guard let sizeBytes else { return filename }
        return "\(filename), \(sizeBytes.formatted(.byteCount(style: .file)))"
    }
}
