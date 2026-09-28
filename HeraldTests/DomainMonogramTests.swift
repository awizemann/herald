import Foundation
import HeraldKit
import Testing
@testable import Herald

/// `DomainMonogram`: the badge letters a domain draws — derivation, clash
/// promotion to three letters, and override validation/precedence.
@Suite struct DomainMonogramTests {
    static func domain(_ id: String, _ name: String) -> MailDomain {
        MailDomain(id: id, name: name, mailboxIDs: [])
    }

    // MARK: - derive(from:)

    @Test("Two letters from the first DNS label, uppercased")
    func derivesTwoLetters() {
        #expect(DomainMonogram.derive(from: "acme.co") == "AC")
        #expect(DomainMonogram.derive(from: "northwind.io") == "NO")
        #expect(DomainMonogram.derive(from: "fieldnotes.press") == "FI")
    }

    @Test("A single-letter first label yields one letter, not a fabricated pad")
    func oneLetterLabel() {
        #expect(DomainMonogram.derive(from: "x.co") == "X")
    }

    @Test("Digits in the first label are kept, not stripped")
    func digitsKept() {
        #expect(DomainMonogram.derive(from: "123.com") == "12")
    }

    @Test("A punycode (IDN) label does not crash and yields its own first two ASCII characters")
    func punycodeLabel() {
        #expect(DomainMonogram.derive(from: "xn--mnchen-3ya.de") == "XN")
    }

    @Test("An empty domain name derives an empty monogram rather than crashing")
    func emptyDomainName() {
        #expect(DomainMonogram.derive(from: "") == "")
    }

    // MARK: - normalizeOverride(_:)

    @Test("A valid 2-3 letter override is trimmed and uppercased")
    func normalizeValidOverride() {
        #expect(DomainMonogram.normalizeOverride(" ac ") == "AC")
        #expect(DomainMonogram.normalizeOverride("nor") == "NOR")
    }

    @Test("An override outside 2-3 characters is rejected")
    func normalizeRejectsWrongLength() {
        #expect(DomainMonogram.normalizeOverride("A") == nil)
        #expect(DomainMonogram.normalizeOverride("ABCD") == nil)
        #expect(DomainMonogram.normalizeOverride("") == nil)
    }

    @Test("An override with punctuation is rejected — it would not read as a monogram")
    func normalizeRejectsPunctuation() {
        #expect(DomainMonogram.normalizeOverride("A!") == nil)
        #expect(DomainMonogram.normalizeOverride("A C") == nil)
    }

    @Test("An override of digits is accepted (a domain's first label can be numeric)")
    func normalizeAcceptsDigits() {
        #expect(DomainMonogram.normalizeOverride("42") == "42")
    }

    // Audit F3 #8: restricted to ASCII A-Z/0-9 — `Character.isLetter` alone
    // accepted any Unicode letter, including an accented one built from a
    // combining sequence ("e" + a combining acute is ONE `Character`, and
    // `.isLetter` on it is true, but it is not ASCII).
    @Test("A non-ASCII letter (accented, combining, or a CJK ideograph) is rejected")
    func normalizeRejectsNonASCIILetters() {
        #expect(DomainMonogram.normalizeOverride("e\u{0301}C") == nil, "a combining sequence, one Character, not ASCII")
        #expect(DomainMonogram.normalizeOverride("ÀC") == nil, "precomposed accented letter, still not ASCII")
        #expect(DomainMonogram.normalizeOverride("日本") == nil)
    }

    // MARK: - assign(domains:overrides:) — clash resolution

    @Test("Two domains that would derive the same two letters both promote to three")
    func clashPromotesToThreeLetters() {
        let result = DomainMonogram.assign(domains: [
            Self.domain("dom_1", "northwind.io"),
            Self.domain("dom_2", "notion.co"),
        ])

        #expect(result["dom_1"] == "NOR")
        #expect(result["dom_2"] == "NOT")
    }

    @Test("A domain with no two-letter clash stays at two letters")
    func noClashStaysTwoLetters() {
        let result = DomainMonogram.assign(domains: [
            Self.domain("dom_1", "acme.co"),
            Self.domain("dom_2", "zeta.test"),
        ])

        #expect(result["dom_1"] == "AC")
        #expect(result["dom_2"] == "ZE")
    }

    @Test("Three or more domains sharing a two-letter prefix are ALL promoted, not just the first two")
    func groupOfThreeAllPromoted() {
        let result = DomainMonogram.assign(domains: [
            Self.domain("dom_1", "acme.co"),
            Self.domain("dom_2", "acorn.io"),
            Self.domain("dom_3", "actual.dev"),
        ])

        #expect(result["dom_1"] == "ACM")
        #expect(result["dom_2"] == "ACO")
        #expect(result["dom_3"] == "ACT")
    }

    @Test("A clash that still matches at three letters is accepted, not crashed or infinitely promoted")
    func stillClashingAtThreeLettersIsAccepted() {
        let result = DomainMonogram.assign(domains: [
            Self.domain("dom_1", "notion.io"),
            Self.domain("dom_2", "notable.dev"),
        ])

        // Both "notion" and "notable" derive "NOT" at three letters — the design
        // guarantees uniqueness only up to three letters, so both keep it.
        #expect(result["dom_1"] == "NOT")
        #expect(result["dom_2"] == "NOT")
    }

    @Test("A per-domain override wins outright, even one that would otherwise clash")
    func overrideWins() {
        let result = DomainMonogram.assign(
            domains: [
                Self.domain("dom_1", "northwind.io"),
                Self.domain("dom_2", "notion.co"),
            ],
            overrides: ["dom_1": "NW"]
        )

        #expect(result["dom_1"] == "NW")
        // dom_2 is unaffected by dom_1's override — it is the only domain left
        // in the auto-derive pool, so it stays at two letters even though it
        // would have clashed with dom_1's ORIGINAL derivation.
        #expect(result["dom_2"] == "NO")
    }

    @Test("An invalid override is ignored and the domain falls through to derivation")
    func invalidOverrideFallsThrough() {
        let result = DomainMonogram.assign(
            domains: [Self.domain("dom_1", "acme.co")],
            overrides: ["dom_1": "!"]
        )

        #expect(result["dom_1"] == "AC")
    }
}
