import SwiftUI
import UniformTypeIdentifiers

/// One attachment, as a card (handoff §3.1 "Attachments", §3.3 Body).
///
/// The same card in the reading pane and the composer: a file-type tile, the
/// name over its size, then Quick Look and Download; the composer adds a
/// divider and Remove. Any action left `nil` is not drawn — a reopened draft's
/// attachment has no local copy, so it gets Remove only.
struct AttachmentCard: View {
    let filename: String
    var contentType: String?
    /// `nil` when the size is unknown (a file that could not be stat'd).
    var sizeBytes: Int?
    /// An upload or download on its way: the tile becomes a spinner and the card
    /// dims, so a finished attachment is never mistaken for one in flight.
    var isInFlight = false
    var inFlightDescription = "Uploading"
    var onQuickLook: (() -> Void)?
    var onDownload: (() -> Void)?
    var onRemove: (() -> Void)?
    /// An upload still in flight: its cancel replaces Remove.
    var onCancel: (() -> Void)?

    static let height: CGFloat = 44
    static let minWidth: CGFloat = 220
    /// Cap in a flow row, so one very long filename does not take a whole row.
    static let maxWidth: CGFloat = 320
    static let tileSize: CGFloat = 28
    /// The tile's corner (the handoff's 6px sits between `Radius.sm` and `.md`).
    private static let tileRadius: CGFloat = MailTheme.Radius.sm + 1

    var body: some View {
        HStack(spacing: MailTheme.Spacing.sm + 2) {
            tile
            VStack(alignment: .leading, spacing: 1) {
                Text(filename)
                    .textStyle(MailTheme.Typography.attachmentName)
                    .foregroundStyle(MailTheme.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sizeText {
                    Text(sizeText)
                        .textStyle(MailTheme.Typography.count)
                        .foregroundStyle(MailTheme.Color.ink3)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
            buttons
        }
        .padding(.leading, MailTheme.Spacing.sm)
        .padding(.trailing, MailTheme.Spacing.xxs)
        .frame(minWidth: Self.minWidth, minHeight: Self.height, maxHeight: Self.height)
        .background(MailTheme.Color.bg, in: RoundedRectangle(cornerRadius: MailTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: MailTheme.Radius.md)
                .strokeBorder(MailTheme.Color.line, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: MailTheme.Radius.md))
        .opacity(isInFlight ? 0.6 : 1)
        // Space = Quick Look on the focused card, as in Finder (§3.1 "eye, Space").
        .focusable(onQuickLook != nil)
        .onKeyPress(.space) {
            guard let onQuickLook else { return .ignored }
            onQuickLook()
            return .handled
        }
        // One element per attachment: VoiceOver reads "invoice.pdf, 88 KB" and
        // offers the card's actions, instead of four unrelated stops.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(isInFlight ? inFlightDescription : "")
        // Only the actions this card really offers: a no-op "Download" on a
        // reopened draft's attachment would be a lie VoiceOver reads out.
        .modifier(OptionalAccessibilityAction(name: "Quick Look", action: onQuickLook))
        .modifier(OptionalAccessibilityAction(name: "Download", action: onDownload))
        .modifier(OptionalAccessibilityAction(name: "Remove", action: onRemove))
        .modifier(OptionalAccessibilityAction(name: "Cancel Upload", action: onCancel))
    }

    private var tile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.tileRadius).fill(MailTheme.Color.lineSoft)
            if isInFlight {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: MailTheme.Symbol.fileType(filename: filename, contentType: contentType))
                    .foregroundStyle(MailTheme.Color.ink2)
            }
        }
        .frame(width: Self.tileSize, height: Self.tileSize)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 0) {
            if let onQuickLook {
                AttachmentCardButton(symbol: MailTheme.Symbol.quickLook, label: "Quick Look \(filename)",
                                     help: "Quick Look (Space)", action: onQuickLook)
            }
            if let onDownload {
                AttachmentCardButton(symbol: MailTheme.Symbol.download, label: "Download \(filename)",
                                     help: "Download", action: onDownload)
            }
            if let trailing = onRemove ?? onCancel {
                if onQuickLook != nil || onDownload != nil {
                    Divider().frame(height: MailTheme.compactIconButtonDiameter - MailTheme.Spacing.sm)
                        .padding(.horizontal, MailTheme.Spacing.xxs)
                }
                AttachmentCardButton(
                    symbol: onRemove != nil ? MailTheme.Symbol.removeAttachment : MailTheme.Symbol.cancelUpload,
                    label: onRemove != nil ? "Remove \(filename)" : "Cancel uploading \(filename)",
                    help: onRemove != nil ? "Remove" : "Cancel upload",
                    tint: MailTheme.Color.ink3,
                    action: trailing
                )
            }
        }
    }

    private var sizeText: String? {
        sizeBytes.map { $0.formatted(.byteCount(style: .file)) }
    }

    private var accessibilityText: String {
        guard let sizeText else { return filename }
        return "\(filename), \(sizeText)"
    }
}

/// A card's icon button: DRAWN at 24pt (the handoff), CLICKABLE over the 28pt
/// minimum hit target — the frame and content shape are 28, the hover plate 24.
private struct AttachmentCardButton: View {
    let symbol: String
    let label: String
    let help: String
    var tint: Color = MailTheme.Color.ink2
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(isHovered ? MailTheme.Color.ink : tint)
                .frame(width: MailTheme.compactIconButtonDiameter, height: MailTheme.compactIconButtonDiameter)
                .background(
                    isHovered ? MailTheme.Color.lineSoft : .clear,
                    in: RoundedRectangle(cornerRadius: MailTheme.Radius.sm)
                )
                .frame(width: MailTheme.hitTarget, height: MailTheme.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}

private struct OptionalAccessibilityAction: ViewModifier {
    let name: String
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.accessibilityAction(named: name, action)
        } else {
            content
        }
    }
}

extension MailTheme.Symbol {
    /// The file-type tile's glyph. The EXTENSION wins over the content type:
    /// servers label a great many parts `application/octet-stream`, while the
    /// name the sender gave the file is usually specific.
    nonisolated static func fileType(filename: String, contentType: String?) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let symbol = symbol(forExtension: ext) { return symbol }
        let type = (contentType ?? "").lowercased()
        if let preferred = UTType(mimeType: type)?.preferredFilenameExtension,
           let symbol = symbol(forExtension: preferred) {
            return symbol
        }
        if type.hasPrefix("image/") { return "photo" }
        if type.hasPrefix("video/") { return "film" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type.hasPrefix("text/") { return "doc.plaintext" }
        return "doc"
    }

    private nonisolated static func symbol(forExtension ext: String) -> String? {
        switch ext {
        case "pdf": "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "svg": "photo"
        case "mov", "mp4", "m4v", "avi", "mkv", "webm": "film"
        case "mp3", "m4a", "wav", "aac", "aiff", "flac", "ogg": "waveform"
        case "zip", "gz", "tgz", "tar", "7z", "rar", "bz2", "xz": "doc.zipper"
        case "xls", "xlsx", "csv", "numbers", "ods": "tablecells"
        case "ppt", "pptx", "key", "odp": "rectangle.on.rectangle"
        case "doc", "docx", "pages", "rtf", "odt": "doc.text"
        case "txt", "md", "log": "doc.plaintext"
        case "ics": "calendar"
        case "vcf": "person.crop.rectangle"
        case "eml": "envelope"
        default: nil
        }
    }
}

/// Cards in a wrapping row (§3.1: "Cards wrap in a row, gap 8"). Each card
/// takes its ideal width, clamped to `maxItemWidth` and to the row.
struct AttachmentFlowLayout: Layout {
    let spacing: CGFloat
    let maxItemWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let ideal = subviews[index].sizeThatFits(.unspecified)
            let itemWidth = min(ideal.width, maxItemWidth, width)
            let size = CGSize(width: itemWidth, height: ideal.height)
            let needed = row.items.isEmpty ? itemWidth : row.width + spacing + itemWidth
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? itemWidth : row.width + spacing + itemWidth
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
