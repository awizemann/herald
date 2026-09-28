import Foundation
import Testing

/// Herald draws its own text in the bundled faces (Geist / Source Serif 4 /
/// Geist Mono) through `MailTheme.Typography`. This scan fails when a view
/// spells a system text style (`.font(.callout)`, `.font(.system(...))`,
/// `Font.caption`, …) instead, so a stray system font cannot creep back in.
/// `MailTheme.swift` is the one allowed home: it names the few system sizes
/// that remain on purpose (SF Symbol glyphs, the fallback constructor).
struct AppFontGuardTests {
    private static let styles = "system|largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2"
    private static let allowlist: Set<String> = ["Design/MailTheme.swift"]

    @Test func noViewSpellsASystemTextStyle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Herald")
        let pattern = try Regex(#"\.font\(\s*(Font)?\.(\#(Self.styles))\b|\bFont\.(\#(Self.styles))\b"#)
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            scanned += 1
            guard !Self.allowlist.contains(relative) else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && line.contains(pattern) {
                offenders.append("\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(scanned > 50, "scan found too few sources — the path is wrong")
        #expect(offenders.isEmpty, "use MailTheme.Typography instead:\n\(offenders.joined(separator: "\n"))")
    }
}
