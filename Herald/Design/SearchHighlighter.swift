import SwiftUI

/// Marks the search query inside a row's text.
///
/// Pure and `nonisolated` so the match arithmetic — which is the half that is
/// easy to get wrong (overlaps, empty needles, case and diacritic folding) — is
/// assertable without a rendered row.
///
/// The emphasis is deliberately NOT colour alone: a match is drawn bold AND on a
/// tinted fill, so it survives greyscale, Increase Contrast and a colour-blind
/// reader (see the design system's "never colour alone" rule).
nonisolated enum SearchHighlighter {
    /// How many matches are marked in one string. A pathological needle ("e")
    /// against a two-line snippet is bounded work; past this the run is left
    /// plain rather than shredded into hundreds of attribute runs.
    static let maximumMatches = 40

    /// Every non-overlapping occurrence of `query` in `text`, case- and
    /// diacritic-insensitively, left to right.
    ///
    /// An empty or whitespace-only query matches nothing: `String.range(of: "")`
    /// answers a degenerate empty range, which would otherwise loop forever.
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !text.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex, found.count < maximumMatches {
            guard let range = text.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<text.endIndex
            ) else { break }
            // Case/diacritic folding can match a run of a different length than
            // the needle, and in principle an empty one; an empty match would
            // never advance the cursor.
            guard !range.isEmpty else { break }
            found.append(range)
            searchStart = range.upperBound
        }
        return found
    }

    /// `text` with every match of `query` emphasised.
    ///
    /// Returns the plain string when there is nothing to mark, so a row with no
    /// active search pays only one `AttributedString` initialisation.
    static func highlight(_ text: String, matching query: String) -> AttributedString {
        let matches = ranges(of: query, in: text)
        guard !matches.isEmpty else { return AttributedString(text) }
        var result = AttributedString()
        var cursor = text.startIndex
        for range in matches {
            result.append(AttributedString(String(text[cursor..<range.lowerBound])))
            var match = AttributedString(String(text[range]))
            match.foregroundColor = MailTheme.searchMatchForeground
            match.backgroundColor = MailTheme.searchMatchBackground
            match.inlinePresentationIntent = .stronglyEmphasized
            result.append(match)
            cursor = range.upperBound
        }
        result.append(AttributedString(String(text[cursor...])))
        return result
    }
}
