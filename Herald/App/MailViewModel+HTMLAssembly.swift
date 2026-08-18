import Foundation

extension MailViewModel {
    // MARK: - HTML assembly

    /// Only media types a mail body may legitimately inline. Anything else
    /// (`text/html`, `application/*`, an empty type) is skipped rather than turned
    /// into a `data:` URL.
    nonisolated static func isRenderableInlineMedia(_ mimeType: String) -> Bool {
        let type = mimeType
            .prefix { $0 != ";" }
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return ["image/", "video/", "audio/"].contains { type.hasPrefix($0) && type.count > $0.count }
    }

    nonisolated static func normalizedContentID(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }

    /// Replaces `cid:` references with the data URLs we already fetched.
    nonisolated static func substituteInlineImages(in html: String, with images: [String: String]) -> String {
        guard !images.isEmpty else { return html }
        var output = html
        for (contentID, dataURL) in images {
            output = output.replacingOccurrences(of: "cid:\(contentID)", with: dataURL)
            output = output.replacingOccurrences(of: "cid:<\(contentID)>", with: dataURL)
        }
        return output
    }

    /// Defence in depth behind the rule list and the navigation delegate: even a
    /// render where the blocker is somehow absent cannot fetch, frame, submit or
    /// rebase anything. `allowsRemote` is only ever true once the user has
    /// explicitly trusted the sender's remote media.
    nonisolated static func contentSecurityPolicy(allowsRemote: Bool) -> String {
        let img = allowsRemote ? "data: cid: https: http:" : "data: cid:"
        return [
            "default-src 'none'",
            "img-src \(img)",
            "style-src 'unsafe-inline'",
            "font-src data:",
            "media-src data:",
            "form-action 'none'",
            "frame-src 'none'",
            "base-uri 'none'",
        ].joined(separator: "; ")
    }

    /// The document title VoiceOver announces when it enters the web area, with a
    /// fallback for an untitled message. Escaped: it is the sender's text.
    nonisolated static func documentTitle(_ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return escapingHTML(trimmed.isEmpty ? "Message" : trimmed)
    }

    nonisolated static func escapingHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// `lang` and `<title>` are not decoration: without them VoiceOver announces
    /// the web area as untitled HTML content and reads the body with the wrong
    /// language's pronunciation rules.
    nonisolated static func document(
        wrapping bodyHTML: String,
        title: String = "",
        allowsRemote: Bool = false
    ) -> String {
        """
        <!doctype html><html lang="\(Locale.current.language.minimalIdentifier)"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy(allowsRemote: allowsRemote))">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(documentTitle(title))</title>
        <style>\(styleSheet)</style></head><body>\(bodyHTML)</body></html>
        """
    }

    nonisolated static func document(wrappingPlainText text: String, title: String = "") -> String {
        document(wrapping: "<pre class=\"plain\">\(escapingHTML(text))</pre>", title: title)
    }

    private nonisolated static let styleSheet = """
        :root { color-scheme: light dark; }
        body { font: -apple-system-body; font-family: -apple-system, system-ui, sans-serif;
               margin: 16px; word-break: break-word; }
        img, video, table { max-width: 100%; height: auto; }
        pre.plain { font-family: ui-monospace, SFMono-Regular, monospace; white-space: pre-wrap; }
        blockquote { border-left: 3px solid rgba(127,127,127,.4); margin-left: 0; padding-left: 12px; }
        """
}
