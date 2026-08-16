import Foundation

/// Turns the server's raw `snippet` (a slice of the plain-text body) into one
/// clean preview line: quoted history and the "On … wrote:" attribution are
/// dropped, HTML entities decoded, control characters and runs of whitespace
/// collapsed. Pure and `nonisolated` so rows and tests use it without a hop.
nonisolated enum SnippetCleaner {
    static func clean(_ raw: String) -> String {
        var kept: [String] = []
        for line in raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") { continue }                     // quoted history
            if isAttribution(trimmed) { break }                        // "On …, x wrote:" — everything after is quote
            if trimmed.hasPrefix("---") && trimmed.lowercased().contains("forwarded message") { break }
            kept.append(trimmed)
        }
        var text = kept.joined(separator: " ")
        // The server slices bodies mid-attribution too: strip a trailing "On …" fragment
        // that never reached its "wrote:".
        if let range = text.range(of: #"\s+On\s+[A-Z][a-z]{2}\s+\d{1,2},\s+\d{4}.*$"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        text = decodeEntities(text)
        text = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == " " }.map(String.init).joined()
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAttribution(_ line: String) -> Bool {
        // "On Aug 15, 2026 at 6:43 PM, someone@example.com wrote:" (and localized-ish variants ending in "wrote:")
        line.hasPrefix("On ") && line.hasSuffix("wrote:")
    }

    private static let entities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
    ]

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        for (k, v) in entities { out = out.replacingOccurrences(of: k, with: v) }
        // Numeric entities: &#8217; / &#x2019;
        if let re = try? NSRegularExpression(pattern: #"&#(x?)([0-9A-Fa-f]+);"#) {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let isHex = m.range(at: 1).length == 1
                let digits = ns.substring(with: m.range(at: 2))
                if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    result.unicodeScalars.append(scalar)
                } else {
                    result += ns.substring(with: m.range)
                }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out
    }
}
