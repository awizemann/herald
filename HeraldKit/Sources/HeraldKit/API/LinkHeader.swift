import Foundation

/// Reads the pagination cursor out of an RFC 8288 `Link` response header.
///
/// The server sends `Link: <https://host/api/v1/messages?folder=inbox&cursor=…>; rel="next"`
/// and omits the header entirely on the last page. Everything here is
/// deliberately tolerant: a header we cannot parse means "no next page", never a
/// thrown error — a malformed header must not fail an otherwise good listing.
nonisolated enum LinkHeader {
    /// The `cursor` query item of the `rel="next"` link, or `nil`.
    static func nextCursor(from header: String?) -> String? {
        guard let header else { return nil }
        for link in splitLinks(header) {
            guard isNext(link), let target = target(of: link) else { continue }
            guard let components = URLComponents(string: target) else { continue }
            guard let cursor = components.queryItems?.first(where: { $0.name == "cursor" })?.value,
                  !cursor.isEmpty
            else { continue }
            return cursor
        }
        return nil
    }

    /// Splits on the commas that separate links, not on commas inside `<…>`.
    private static func splitLinks(_ header: String) -> [String] {
        var links: [String] = []
        var current = ""
        var insideAngleBrackets = false
        for character in header {
            switch character {
            case "<": insideAngleBrackets = true; current.append(character)
            case ">": insideAngleBrackets = false; current.append(character)
            case "," where !insideAngleBrackets:
                links.append(current)
                current = ""
            default: current.append(character)
            }
        }
        links.append(current)
        return links
    }

    /// `rel="next"`, `rel=next` and `rel='next'` all count.
    private static func isNext(_ link: String) -> Bool {
        for parameter in link.split(separator: ";").dropFirst() {
            let trimmed = parameter.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("rel=") else { continue }
            let value = trimmed.dropFirst("rel=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if value.lowercased() == "next" { return true }
        }
        return false
    }

    private static func target(of link: String) -> String? {
        guard let start = link.firstIndex(of: "<"), let end = link.firstIndex(of: ">"), start < end else {
            return nil
        }
        return String(link[link.index(after: start)..<end])
    }
}
