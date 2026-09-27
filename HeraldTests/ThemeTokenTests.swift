import AppKit
import HeraldKit
import SwiftUI
import Testing
import WebKit
@testable import Herald

/// The four looks a token has to hold up in.
private enum Look {
    case light, dark, lightHC, darkHC
}

private let light = Look.light
private let dark = Look.dark
private let lightHC = Look.lightHC
private let darkHC = Look.darkHC

/// Resolves a token to sRGB hex exactly the way a view does: through SwiftUI's
/// environment (colour scheme AND contrast). Bridging to `NSColor` under an
/// `NSAppearance` would not do — it never picks the asset's Increase Contrast
/// entries, because SwiftUI takes contrast from its environment.
@MainActor
private func hex(_ color: SwiftUI.Color, _ look: Look) -> String {
    var environment = EnvironmentValues()
    environment.colorScheme = (look == .dark || look == .darkHC) ? .dark : .light
    environment._colorSchemeContrast = (look == .lightHC || look == .darkHC) ? .increased : .standard
    let resolved = color.resolve(in: environment)
    func byte(_ component: Float) -> Int { Int((Double(min(max(component, 0), 1)) * 255).rounded()) }
    return String(format: "#%02x%02x%02x", byte(resolved.red), byte(resolved.green), byte(resolved.blue))
}

/// The redesign's colour tokens are asset-catalogue colour sets looked up by
/// NAME (they must stay `nonisolated`, which the generated symbols are not), so
/// nothing but these tests notices a typo, a missing appearance or a dropped
/// Increase Contrast variant — each of which draws a wrong colour, not an error.
@MainActor
@Suite struct ThemeColorTokenTests {
    /// Handoff §1, both appearances. A misspelt asset name resolves to no colour
    /// (or clear) and a colour set missing its Dark entry resolves to the light
    /// value — both fail here.
    @Test func everyColourTokenResolvesToTheHandoffValueInBothAppearances() {
        let expected: [(String, SwiftUI.Color, String, String?)] = [
            ("bg", MailTheme.Color.bg, "#fbfcfd", "#111315"),
            ("sidebar", MailTheme.Color.sidebar, "#f1f3f5", "#0b0c0f"),
            ("surface", MailTheme.Color.surface, "#ffffff", "#191b1e"),
            ("line", MailTheme.Color.line, "#dbdee2", "#2e3035"),
            ("lineSoft", MailTheme.Color.lineSoft, "#e9ebee", "#222428"),
            ("ink", MailTheme.Color.ink, "#13161c", "#eef0f3"),
            ("ink2", MailTheme.Color.ink2, "#4e535a", "#a7abb1"),
            ("ink3", MailTheme.Color.ink3, "#6e7279", "#82868c"),
            ("accent", MailTheme.Color.accent, "#2e62c9", "#73a3fc"),
            ("onAccent", MailTheme.Color.onAccent, "#ffffff", "#090d16"),
            ("select", MailTheme.Color.select, "#dbe9ff", "#202e47"),
            ("star", MailTheme.Color.star, "#e5a323", "#edb345"),
            ("danger", MailTheme.Color.danger, "#c9302d", "#f27166"),
            // Dark `ok` is the system green, not a fixed value: only "resolves
            // to something other than the light value" is asserted below.
            ("ok", MailTheme.Color.ok, "#2d8949", nil),
            ("warn", MailTheme.Color.warn, "#c8800d", "#eeb154"),
            ("match", MailTheme.Color.match, "#f6e697", "#6e5d14"),
        ]
        for (name, color, lightValue, darkValue) in expected {
            #expect(hex(color, light) == lightValue, "\(name) light")
            if let darkValue {
                #expect(hex(color, dark) == darkValue, "\(name) dark")
            } else {
                #expect(hex(color, dark) != lightValue, "\(name) dark")
            }
        }
    }

    /// The tokens that carry text or boundaries must move under Increase
    /// Contrast, and TOWARD the ink — darker in light mode, lighter in dark: the
    /// property `systemRed`/`.secondary` had for free and a plain hex colour
    /// loses. A colour set that dropped its high-contrast entries resolves to
    /// the base value and fails.
    @Test func textAndBoundaryTokensHaveIncreaseContrastVariants() {
        let tokens: [(String, SwiftUI.Color)] = [
            ("line", MailTheme.Color.line), ("lineSoft", MailTheme.Color.lineSoft),
            ("ink2", MailTheme.Color.ink2), ("ink3", MailTheme.Color.ink3),
            ("accent", MailTheme.Color.accent), ("danger", MailTheme.Color.danger),
        ]
        for (name, color) in tokens {
            #expect(luminance(hex(color, lightHC)) < luminance(hex(color, light)), "\(name) light HC")
            #expect(luminance(hex(color, darkHC)) > luminance(hex(color, dark)), "\(name) dark HC")
        }
    }

    private func luminance(_ hex: String) -> Double {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        let channels = [(value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff].map { Double($0) / 255 }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }

    /// The status tokens were repointed at the design tokens; a view still
    /// reading `MailTheme.failure` must get `danger`, not the old systemRed.
    @Test func statusTokensDrawTheDesignColours() {
        #expect(hex(MailTheme.failure, light) == "#c9302d")
        #expect(hex(MailTheme.starred, light) == "#e5a323")
        #expect(hex(MailTheme.unreadIndicator, dark) == "#73a3fc")
        #expect(hex(MailTheme.searchMatchBackground, light) == "#f6e697")
        #expect(hex(MailTheme.selectionHighlight, dark) == "#202e47")
    }
}

/// The contract with the account-tint ASSIGNMENT (phase R2): it hashes an
/// account id to an index into `accountTints` and persists overrides by name.
@MainActor
@Suite struct AccountTintTokenTests {
    /// Reordering or renaming repaints every account that has no override and
    /// orphans every stored override — the order and names are persisted.
    @Test func tintsAreTheEightNamedTokensInContractOrder() {
        #expect(MailTheme.accountTints.map(\.name)
            == ["clay", "ochre", "moss", "sage", "slate", "dusk", "plum", "rose"])
    }

    @Test func eachTintDrawsItsHandoffSolidAndAvatarText() {
        let expected: [String: (String, String)] = [
            "clay": ("#c87a6d", "#301814"), "ochre": ("#b98749", "#2b1c08"),
            "moss": ("#8d9b51", "#1e220a"), "sage": ("#55a57d", "#0b2519"),
            "slate": ("#37a1b8", "#02242b"), "dusk": ("#7092d0", "#151f32"),
            "plum": ("#a581c0", "#251a2d"), "rose": ("#c27895", "#2e1720"),
        ]
        for tint in MailTheme.accountTints {
            let (solid, text) = expected[tint.name] ?? ("?", "?")
            // Same in both appearances: the handoff defines one value.
            for appearance in [light, dark] {
                #expect(hex(tint.solid, appearance) == solid, "\(tint.name) solid")
                #expect(hex(tint.avatarText, appearance) == text, "\(tint.name) text")
            }
        }
    }

    /// A stale or foreign override (an old mailbox-palette name, another case)
    /// must read as "no override", so the hash default applies.
    @Test func lookupIsExactAndRejectsUnknownNames() {
        #expect(MailTheme.accountTint(named: "dusk")?.name == "dusk")
        for name in ["Dusk", "blue", "", " clay"] {
            #expect(MailTheme.accountTint(named: name) == nil, "\(name)")
        }
    }
}

@MainActor
@Suite struct LabelColourTokenTests {
    /// The ten server colour names translate to the handoff's values; a case
    /// wired to the wrong asset (or left on the old systemX colour) fails.
    @Test func everyServerLabelColourDrawsItsHandoffValue() {
        let expected: [LabelColor: String] = [
            .gray: "#929292", .red: "#c87973", .orange: "#c37f59", .amber: "#b28b45",
            .green: "#6aa36c", .teal: "#33a6a0", .blue: "#5a98cb", .indigo: "#808dcf",
            .purple: "#a082c3", .pink: "#c0789b",
        ]
        for color in LabelColor.allCases {
            #expect(hex(MailTheme.labelTint(for: color), light) == expected[color], "\(color)")
        }
    }
}

/// The reading pane's CSS palette is a hand-kept copy of the colour tokens (a
/// web view cannot read a `Color`). Pinning each value to the resolved asset
/// is what stops the two drifting apart.
@MainActor
@Suite struct WebPaletteTokenTests {
    @Test func webPaletteMirrorsTheColourTokensInEveryAppearance() {
        let cases: [(MailTheme.Web.Palette, Look, Look)] = [
            (MailTheme.Web.light, light, lightHC), (MailTheme.Web.dark, dark, darkHC),
        ]
        for (palette, appearance, high) in cases {
            #expect(palette.foreground == hex(MailTheme.Color.ink, appearance))
            #expect(palette.secondary == hex(MailTheme.Color.ink2, appearance))
            #expect(palette.background == hex(MailTheme.Color.surface, appearance))
            #expect(palette.link == hex(MailTheme.Color.accent, appearance))
            #expect(palette.quoteBars == [
                hex(MailTheme.Color.accent, appearance),
                MailTheme.accountTint(named: "slate").map { hex($0.solid, appearance) },
                MailTheme.accountTint(named: "sage").map { hex($0.solid, appearance) },
            ])
            #expect(palette.secondaryIncreasedContrast == hex(MailTheme.Color.ink2, high))
            #expect(palette.linkIncreasedContrast == hex(MailTheme.Color.accent, high))
        }
    }
}

/// The bundled fonts are registered by `ATSApplicationFontsPath`; if the folder
/// is not copied, the key is missing, or a file is renamed, `Font.custom`
/// silently draws the system font. These run inside the app host, so they see
/// exactly what the app sees.
@MainActor
@Suite struct FontRegistrationTests {
    @Test func everyBundledFaceResolvesByPostScriptName() throws {
        #expect(MailTheme.Typography.usesBundledFonts)
        for face in MailTheme.Typography.Face.allCases {
            let font = try #require(NSFont(name: face.rawValue, size: 13), "\(face.rawValue) not registered")
            #expect(font.fontName == face.rawValue)
        }
    }

    /// `lineHeight` is a CSS multiple; SwiftUI adds `lineSpacing` to the face's
    /// natural line. Converting against a guessed natural height (or not at
    /// all) misses the handoff's 14 / 1.6 reading line.
    @Test func lineSpacingProducesTheSpecifiedLineHeight() throws {
        let style = MailTheme.Typography.reading
        let font = try #require(NSFont(name: style.face.rawValue, size: style.size))
        let natural = font.ascender - font.descender + font.leading
        #expect(abs(natural + style.lineSpacing - 14 * 1.6) < 0.01)
        #expect(MailTheme.Typography.headline.lineSpacing == 0)
    }

    /// Tracking is stored as a fraction of the size (CSS em) and applied in
    /// points; the section style is also the only uppercased one.
    @Test func trackingIsConvertedToPoints() {
        #expect(abs(MailTheme.Typography.section.trackingPoints - 11 * 0.06) < 0.0001)
        #expect(abs(MailTheme.Typography.display.trackingPoints - 34 * -0.015) < 0.0001)
        #expect(MailTheme.Typography.section.uppercased)
        #expect(!MailTheme.Typography.body.uppercased)
    }
}

/// Geist in the reading pane arrives as a `data:` font, so it rides the
/// document's EXISTING `font-src data:` policy and the rule list's remote-load
/// blocking stays untouched.
@MainActor
@Suite struct ReadingFontTests {
    @Test func theReadingFontIsEmbeddedAsDataAndNothingElse() throws {
        let document = MailViewModel.document(wrapping: "<p>hi</p>")

        let rule = MailTheme.Web.fontFaceRule
        #expect(rule.contains("src: url(data:font/woff2;base64,"), "Geist-Variable.woff2 not bundled")
        #expect(document.contains(rule))
        #expect(document.contains("--reading-font: \"Geist\", -apple-system"))
        #expect(document.contains("font-size: 14px;"))
        #expect(document.contains("line-height: 1.6;"))

        // Every url( in the wrapper is a data: URL — no bundle path, no network.
        var rest = Substring(document)
        while let range = rest.range(of: "url(") {
            #expect(rest[range.upperBound...].hasPrefix("data:"))
            rest = rest[range.upperBound...]
        }
        // The policy itself is unchanged: data: fonts only.
        let csp = MailViewModel.contentSecurityPolicy(allowsRemote: true)
        #expect(csp.contains("font-src data:;"))
        #expect(csp.components(separatedBy: "font-src").count == 2)
    }

    /// The string checks above cannot tell whether WebKit actually ACCEPTS the
    /// embedded face under the document's CSP. This loads the real wrapping
    /// document and asks the page: a CSP that stopped allowing `font-src data:`,
    /// a corrupt base64 payload or a wrong `format()` all reject the load.
    @Test(.timeLimit(.minutes(1)))
    func geistLoadsInTheWebViewUnderTheLockedDownPolicy() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        webView.loadHTMLString(MailViewModel.document(wrapping: "<p>hi</p>"), baseURL: nil)
        // Poll with an early exit — no fixed sleep-then-assert.
        for _ in 0..<500 where webView.isLoading || webView.url == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let status = try await webView.callAsyncJavaScript(
            """
            const face = [...document.fonts].find(f => f.family.replace(/"/g, '') === 'Geist');
            if (!face) { return 'missing'; }
            try { await face.load(); } catch (error) { return 'rejected'; }
            return face.status;
            """,
            contentWorld: .page
        ) as? String
        #expect(status == "loaded")
    }
}
