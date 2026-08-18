import Foundation

/// A bitmap lifted off the pasteboard: bytes plus the extension that names them.
public nonisolated struct PasteboardImage: Sendable, Hashable {
    public let data: Data
    /// Lowercase, no dot ("png", "jpeg"). Whatever the pasteboard type mapped to.
    public let filenameExtension: String

    public init(data: Data, filenameExtension: String) {
        self.data = data
        self.filenameExtension = filenameExtension
    }
}

/// What the app read off `NSPasteboard`, as a value.
///
/// AppKit's pasteboard is a main-actor global with no seam for tests; this is the
/// seam. The app reads it, this type carries it, and the mapping below is pure.
public nonisolated struct PasteboardContents: Sendable, Hashable {
    public var fileURLs: [URL]
    public var images: [PasteboardImage]
    /// Whether the pasteboard also carries plain text — the signal that a paste
    /// with nothing attachable in it belongs to the text view instead.
    public var hasText: Bool

    public init(fileURLs: [URL] = [], images: [PasteboardImage] = [], hasText: Bool = false) {
        self.fileURLs = fileURLs
        self.images = images
        self.hasText = hasText
    }
}

/// One thing a paste turned into.
public nonisolated enum PastedAttachment: Sendable, Hashable {
    /// A file that already exists on disk and is NOT ours to delete.
    case file(URL)
    /// Bytes with no file behind them; the caller writes them to scratch first.
    case image(PasteboardImage, filename: String)
}

/// Turns a pasteboard into the list of things to attach.
public nonisolated enum AttachmentPasteboard {
    /// - Returns: what to attach, in order. Empty means "this paste is not ours" —
    ///   the caller must forward ⌘V to the text view rather than swallow it.
    ///
    /// File URLs WIN over images: copying a PNG in Finder puts both a file URL and
    /// the rendered image on the pasteboard, and attaching the real file keeps the
    /// user's filename and the original bytes instead of a re-encoded screenshot.
    public static func attachments(from contents: PasteboardContents, now: Date = .now) -> [PastedAttachment] {
        let files = contents.fileURLs.filter(\.isFileURL)
        if !files.isEmpty {
            return files.map { .file($0) }
        }
        // TEXT WINS over a bare image: Preview, Numbers, Keynote and most rich-text
        // sources put a synthesized TIFF/PDF on the pasteboard ALONGSIDE the text,
        // and attaching that would mean ⌘V in the body pastes a screenshot of the
        // selection instead of the selection. A real copied image carries no text.
        guard !contents.hasText else { return [] }
        return contents.images.enumerated().map { index, image in
            .image(image, filename: filename(for: image, index: index, now: now))
        }
    }

    /// `Pasted Image 2026-08-18 at 14.30.05.png` — Screenshot-style, sortable,
    /// and suffixed when one paste carries several images so they cannot collide.
    static func filename(for image: PasteboardImage, index: Int, now: Date) -> String {
        var stamp = now.formatted(
            .verbatim(
                "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
                timeZone: .current,
                calendar: .current
            )
        )
        if index > 0 { stamp += " (\(index + 1))" }
        return "Pasted Image \(stamp).\(image.filenameExtension)"
    }
}
