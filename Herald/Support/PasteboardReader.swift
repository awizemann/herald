import AppKit
import HeraldKit
import UniformTypeIdentifiers

/// Reads `NSPasteboard` into the value type ``PasteboardContents``, which is where
/// the testable half of paste-to-attach lives.
enum PasteboardReader {
    /// Bitmap types worth attaching, best-fidelity first. TIFF is last: AppKit
    /// synthesizes it for almost every image on the pasteboard, so taking it first
    /// would turn every pasted PNG into a fat TIFF.
    private static let imageTypes: [(NSPasteboard.PasteboardType, String)] = [
        (.png, "png"),
        (NSPasteboard.PasteboardType(UTType.jpeg.identifier), "jpeg"),
        (NSPasteboard.PasteboardType(UTType.gif.identifier), "gif"),
        (NSPasteboard.PasteboardType(UTType.heic.identifier), "heic"),
        (.pdf, "pdf"),
        (.tiff, "tiff"),
    ]

    static func contents(of pasteboard: NSPasteboard = .general) -> PasteboardContents {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []

        var images: [PasteboardImage] = []
        if urls.isEmpty, let type = imageTypes.first(where: { pasteboard.data(forType: $0.0) != nil }),
           let data = pasteboard.data(forType: type.0) {
            images.append(PasteboardImage(data: data, filenameExtension: type.1))
        }

        return PasteboardContents(
            fileURLs: urls,
            images: images,
            hasText: pasteboard.canReadObject(forClasses: [NSString.self])
        )
    }
}
