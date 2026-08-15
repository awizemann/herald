import CryptoKit
import Foundation
import Testing
@testable import HeraldKit

@Suite struct PKCETests {
    /// Recomputes the challenge independently. Fails if the challenge is base64
    /// (not base64url), padded, hashed over UTF-16, or hashed over the wrong value.
    @Test("challenge is unpadded base64url of SHA256(verifier)")
    func challengeIsS256OfVerifier() {
        let pkce = PKCE(verifier: String(repeating: "a", count: 43))
        let expected = Data(SHA256.hash(data: Data(pkce.verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        #expect(pkce.challenge == expected)
        #expect(!pkce.challenge.contains("="))
        #expect(PKCE.method == "S256")
    }

    /// Fails if the generator ever emits an out-of-spec verifier — a `+`, `/` or `=`
    /// from plain base64 would be percent-encoded in the authorize URL and the
    /// server's comparison would not match.
    @Test("generated verifiers are 43-128 unreserved characters and never repeat")
    func generatedVerifiersAreValid() {
        var seen = Set<String>()
        for _ in 0..<200 {
            let pkce = PKCE()
            #expect(PKCE.isValid(pkce.verifier))
            #expect((43...128).contains(pkce.verifier.count))
            #expect(seen.insert(pkce.verifier).inserted, "CSPRNG produced a duplicate verifier")
        }
    }

    /// Fails if `isValid` accepts reserved characters or out-of-range lengths.
    @Test("isValid rejects short, long and reserved-character verifiers")
    func validationRejectsBadVerifiers() {
        #expect(!PKCE.isValid(String(repeating: "a", count: 42)))
        #expect(!PKCE.isValid(String(repeating: "a", count: 129)))
        #expect(!PKCE.isValid(String(repeating: "a", count: 42) + "+"))
        #expect(!PKCE.isValid(String(repeating: "a", count: 42) + "/"))
        #expect(PKCE.isValid(String(repeating: "a", count: 42) + "~"))
    }
}
