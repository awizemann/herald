import Foundation

extension MailViewModel {
    // MARK: - HTML assembly

    /// Only media types a mail body may legitimately inline. Anything else
    /// (`text/html`, `application/*`, an empty type) is skipped rather than turned
    /// into a `data:` URL.
    ///
    /// The type/subtype shape is validated first: this value is embedded verbatim
    /// into a `data:` URL (`data:<mimeType>;base64,…`), so accepting anything that
    /// merely starts with `image/`/`video/`/`audio/` would let a subtype carrying
    /// `;`, whitespace, or other URL-breaking characters through on the strength
    /// of that prefix check alone — safety would then rest entirely on whatever
    /// upstream code happens to have already sanitized the value, a cross-file
    /// agreement rather than something this function itself enforces.
    nonisolated static func isRenderableInlineMedia(_ mimeType: String) -> Bool {
        let type = mimeType
            .prefix { $0 != ";" }
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard Self.hasValidMIMETypeShape(type) else { return false }
        return ["image/", "video/", "audio/"].contains { type.hasPrefix($0) && type.count > $0.count }
    }

    /// `type/subtype` where both sides are RFC 2045 `token` characters, narrowed
    /// to the lowercase-ASCII set actually used by `UTType`-derived mime strings
    /// (`^[a-z0-9.+-]+/[a-z0-9.+-]+$`, case-insensitive — `type` is already
    /// lowercased by the caller, but this is also called independently in tests).
    nonisolated static func hasValidMIMETypeShape(_ type: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.+-")
        let parts = type.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.lowercased().unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    nonisolated static func normalizedContentID(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }

    /// Replaces `cid:` references with the data URLs we already fetched.
    ///
    /// Restricted to `src`/`background` ATTRIBUTE positions: a global string
    /// replace also rewrote `cid:` text a human wrote in the body (and any
    /// `cid:` inside an unrelated attribute), which is a silent corruption of
    /// the message. A content ID that fails to fetch is left alone — the raw
    /// `cid:` URL is inert under the CSP.
    nonisolated static func substituteInlineImages(in html: String, with images: [String: String]) -> String {
        guard !images.isEmpty else { return html }
        var output = html
        for (contentID, dataURL) in images {
            let id = NSRegularExpression.escapedPattern(for: contentID)
            let template = NSRegularExpression.escapedTemplate(for: dataURL)
            // `<?id>?` — the reference is written both bare and angle-bracketed.
            let reference = "[cC][iI][dD]:<?\(id)>?"
            // Case-insensitive attribute name: `<IMG SRC=…>` is ordinary mail.
            // QUOTED values only — an unquoted `src=cid:…` cannot be told apart
            // from the same text sitting inside another attribute's value without
            // parsing the tag, and rewriting THAT is the corruption this replaced.
            // The server hands us sanitized HTML, which quotes its attributes.
            let attribute = "(?<=\\s)(?i:src|background)\\s*=\\s*"
            for (pattern, replacement) in [
                ("(\(attribute)\")\(reference)(\")", "$1\(template)$2"),
                ("(\(attribute)')\(reference)(')", "$1\(template)$2"),
            ] {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                output = regex.stringByReplacingMatches(
                    in: output,
                    range: NSRange(output.startIndex..., in: output),
                    withTemplate: replacement
                )
            }
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

    /// Escaping for text that lands inside a QUOTED attribute value. Text content
    /// escaping is not enough there: an unescaped quote closes the value and the
    /// rest of the attacker's string becomes markup.
    nonisolated static func escapingAttribute(_ text: String) -> String {
        escapingHTML(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - Body composition

    /// Composes the three fragments the server splits a message into — authored
    /// body, quoted history, authored content BELOW the quote — into one body.
    ///
    /// The quoted history is a `<details>` closed by default. `<details>` is the
    /// only collapse affordance available here: JavaScript is disabled in the
    /// reading pane, and WebKit's disclosure works natively without it.
    ///
    /// Everything this adds is fixed markup: no sender-controlled text reaches an
    /// attribute or an unescaped position from here (the fragments themselves are
    /// server-sanitized HTML and go in verbatim, as before).
    ///
    /// The fragments are stripped of their own `details`/`summary` tags first.
    /// Not XSS — script is off and the CSP forbids everything — but a sender's
    /// `</details>` would end HERALD's disclosure early and a sender's
    /// `<summary>` would draw a second, sender-written disclosure label: message
    /// content impersonating app chrome.
    nonisolated static func composeBody(
        html: String,
        quotedHTML: String? = nil,
        afterQuotedHTML: String? = nil
    ) -> String {
        func present(_ fragment: String?) -> String? {
            guard let fragment, fragment.contains(where: { !$0.isWhitespace }) else { return nil }
            return withoutDisclosureTags(fragment)
        }
        var sections = ["<section class=\"body\">\(withoutDisclosureTags(html))</section>"]
        if let quoted = present(quotedHTML) {
            sections.append(
                """
                <details class="quoted"><summary>Show quoted history</summary>\
                <section class="body quoted-body">\(quoted)</section></details>
                """
            )
        }
        if let after = present(afterQuotedHTML) {
            sections.append("<section class=\"body after-quoted\">\(after)</section>")
        }
        return sections.joined()
    }

    /// Removes `<details>`/`<summary>` open and close tags (only those two
    /// elements) from a fragment, leaving their inner content in place. The
    /// disclosure belongs to Herald.
    nonisolated static func withoutDisclosureTags(_ fragment: String) -> String {
        guard let regex = disclosureTagRegex, fragment.contains("<") else { return fragment }
        return regex.stringByReplacingMatches(
            in: fragment,
            range: NSRange(fragment.startIndex..., in: fragment),
            withTemplate: ""
        )
    }

    private nonisolated static let disclosureTagRegex = try? NSRegularExpression(
        pattern: "</?(?:details|summary)(?:\\s[^>]*)?/?>", options: [.caseInsensitive]
    )

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
        document(wrapping: plainTextBody(text), title: title)
    }

    // MARK: - Plain text

    /// `text/plain` rendered as a document: the system font (not monospace — mail
    /// is prose, not code), URLs turned into real links, `>` quote lines tinted,
    /// and a trailing quoted history folded into the same disclosure the HTML
    /// path uses.
    nonisolated static func plainTextBody(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let tailStart = quotedTailStart(in: lines)
        // A message that is quoted history top to bottom has no visible half; an
        // empty `<pre>` above the disclosure would draw a stray blank line.
        var body = tailStart == 0 ? "" : "<pre class=\"plain\">\(renderedPlainLines(lines[..<tailStart]))</pre>"
        if tailStart < lines.count {
            body += """
                <details class="quoted"><summary>Show quoted history</summary>\
                <pre class="plain quoted-body">\(renderedPlainLines(lines[tailStart...]))</pre></details>
                """
        }
        return "<section class=\"body\">\(body)</section>"
    }

    /// Index of the first line of the trailing quoted block — the run of `>`
    /// lines that reaches the end of the message, plus the "On … wrote:"
    /// attribution directly above it. `lines.count` when there is no such block.
    nonisolated static func quotedTailStart(in lines: [String]) -> Int {
        var index = lines.count
        while index > 0, lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty { index -= 1 }
        guard index > 0, isQuoteLine(lines[index - 1]) else { return lines.count }
        while index > 0, isQuoteLine(lines[index - 1]) || lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            index -= 1
        }
        // Blank lines swept up above the quote belong to the visible body.
        while index < lines.count, !isQuoteLine(lines[index]) { index += 1 }
        if index > 0, isAttributionLine(lines[index - 1]) { index -= 1 }
        return index
    }

    nonisolated static func isQuoteLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }

    /// "On Tue, 2 Sep 2026, Ada wrote:" and the localized variants that still end
    /// in a colon. Deliberately narrow: a false positive only pulls one extra
    /// line into the disclosure, a false negative leaves it above it.
    nonisolated static func isAttributionLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasSuffix(":") && trimmed.count < 200 && trimmed.contains(" ")
    }

    private nonisolated static func renderedPlainLines(_ lines: ArraySlice<String>) -> String {
        lines.map { line in
            let rendered = linkifying(line)
            return isQuoteLine(line) ? "<span class=\"quote-line\">\(rendered)</span>" : rendered
        }
        .joined(separator: "\n")
    }

    /// Escapes one line of plain text and turns bare `http(s)` URLs into links.
    ///
    /// Order matters and is the whole point: matching runs on the RAW text and
    /// each piece is escaped as it is emitted. Linkifying escaped text instead
    /// would let `&amp;` and `&gt;` be swallowed into hrefs and double-escape the
    /// result. Only `http`/`https` can match, and the URL is attribute-escaped,
    /// so no `javascript:` href and no attribute break-out is reachable from
    /// sender text.
    nonisolated static func linkifying(_ line: String) -> String {
        guard let regex = urlRegex else { return escapingHTML(line) }
        var output = ""
        var cursor = line.startIndex
        for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard var range = Range(match.range, in: line) else { continue }
            // Trailing sentence punctuation is prose, not URL.
            while range.lowerBound < range.upperBound,
                  let last = line[range].last,
                  ".,;:!?".contains(last) || (last == ")" && !line[range].contains("(")) {
                range = range.lowerBound..<line.index(before: range.upperBound)
            }
            guard range.lowerBound < range.upperBound else { continue }
            let url = String(line[range])
            output += escapingHTML(String(line[cursor..<range.lowerBound]))
            // `https://apple.com@evil.example/x` READS as apple.com and OPENS
            // evil.example. Herald is manufacturing this link out of text that
            // was inert, so a deceptive authority stays inert text.
            output += hasDeceptiveAuthority(url)
                ? escapingHTML(url)
                : "<a href=\"\(escapingAttribute(url))\">\(escapingHTML(url))</a>"
            cursor = range.upperBound
        }
        output += escapingHTML(String(line[cursor...]))
        return output
    }

    /// Whether the URL's authority carries userinfo (`user@host`) or a backslash
    /// — the two ways the host a reader sees can differ from the host WebKit
    /// resolves.
    nonisolated static func hasDeceptiveAuthority(_ url: String) -> Bool {
        guard let schemeEnd = url.range(of: "://") else { return true }
        let rest = url[schemeEnd.upperBound...]
        let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return authority.contains("@") || authority.contains("\\") || authority.isEmpty
    }

    /// Stops at whitespace and at the characters that would end a URL in prose or
    /// break out of the emitted markup.
    private nonisolated static let urlRegex = try? NSRegularExpression(
        pattern: "https?://[^\\s<>\"'`]+", options: [.caseInsensitive]
    )

    // MARK: - Stylesheet

    /// Mirrors the ``MailTheme/Web`` palette into CSS custom properties for one
    /// appearance.
    private nonisolated static func variables(_ palette: MailTheme.Web.Palette) -> String {
        """
        --fg: \(palette.foreground); --secondary: \(palette.secondary); --bg: \(palette.background);
        --link: \(palette.link); --quote-1: \(palette.quoteBars[0]); --quote-2: \(palette.quoteBars[1]);
        --quote-3: \(palette.quoteBars[2]); --quote-surface: \(palette.quoteSurface);
        """
    }

    /// The Increase Contrast overrides for one appearance: only the two tokens
    /// Herald actually dims (`--secondary`, `--link`), pushed toward `--fg`.
    private nonisolated static func contrastVariables(_ palette: MailTheme.Web.Palette) -> String {
        "--secondary: \(palette.secondaryIncreasedContrast); --link: \(palette.linkIncreasedContrast);"
    }

    /// Deliberately CONSERVATIVE about dark mode: it styles the document's own
    /// unstyled regions (body text, links, quote bars, the disclosure) and never
    /// touches a colour the sender set. Inverting a designed HTML email wrecks it
    /// far more often than it rescues one.
    private nonisolated static var styleSheet: String {
        """
        :root { color-scheme: light dark; \(variables(MailTheme.Web.light)) }
        @media (prefers-color-scheme: dark) { :root { \(variables(MailTheme.Web.dark)) } }
        /* Increase Contrast (System Settings → Accessibility). Ordered AFTER the
           appearance blocks so it wins at equal specificity, and split per
           appearance because the dark override has to beat the dark palette. */
        @media (prefers-contrast: more) { :root { \(contrastVariables(MailTheme.Web.light)) } }
        @media (prefers-color-scheme: dark) and (prefers-contrast: more) {
            :root { \(contrastVariables(MailTheme.Web.dark)) } }
        body { font: -apple-system-body; font-family: -apple-system, system-ui, sans-serif;
               margin: 16px; word-break: break-word; color: var(--fg); background: var(--bg); }
        a { color: var(--link); }
        img, video, table { max-width: 100%; height: auto; }
        /* Wide tables scroll INSIDE their section instead of forcing the whole
           document sideways. */
        section.body { overflow-x: auto; }
        pre.plain { font-family: -apple-system, system-ui, sans-serif; white-space: pre-wrap;
                    margin: 0; }
        .quote-line { color: var(--secondary); }
        blockquote { border-left: 3px solid var(--quote-1); margin: 12px 0; padding-left: 12px;
                     background: var(--quote-surface); }
        blockquote blockquote { border-left-color: var(--quote-2); }
        blockquote blockquote blockquote { border-left-color: var(--quote-3); }
        blockquote blockquote blockquote blockquote { border-left-color: var(--quote-1); }
        details.quoted { margin-top: 12px; }
        /* `pointer`, not `default`: the summary IS a control (it opens the quoted
           history), and a cursor that never changes said otherwise. */
        details.quoted > summary { cursor: pointer; color: var(--secondary); font-size: 0.9em;
                                   padding: 4px 0; list-style: none; }
        details.quoted > summary::-webkit-details-marker { display: none; }
        details.quoted > summary::before { content: "\\2026\\00a0\\00a0"; }
        details.quoted[open] > summary::before { content: "\\25BE\\00a0\\00a0"; }
        details.quoted > summary:hover { color: var(--fg); }
        section.quoted-body, pre.quoted-body { border-left: 3px solid var(--quote-1);
                                               padding-left: 12px; margin-top: 4px; }
        """
    }
}
