import CryptoKit
import Foundation
import Security

/// An RFC 7636 code verifier / challenge pair. S256 only — the HQBase
/// authorization server rejects `plain`.
public nonisolated struct PKCE: Sendable, Hashable {
    public static let method = "S256"

    /// 43–128 characters from the unreserved set.
    public let verifier: String
    /// base64url(SHA256(ASCII(verifier))), unpadded.
    public let challenge: String

    /// Fresh verifier from the system CSPRNG.
    ///
    /// 32 random bytes base64url-encoded gives exactly 43 unreserved characters —
    /// the RFC's own recommendation, and it avoids the modulo bias a
    /// "pick from an alphabet" generator would introduce.
    public init(byteCount: Int = 32) {
        self.init(verifier: PKCE.randomVerifier(byteCount: byteCount))
    }

    /// Deterministic initializer used by tests and by resuming a stored request.
    /// Traps on an out-of-spec verifier: that is a programming error, not input.
    public init(verifier: String) {
        precondition(PKCE.isValid(verifier), "PKCE verifier must be 43-128 unreserved characters")
        self.verifier = verifier
        self.challenge = PKCE.challenge(for: verifier)
    }

    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    /// unreserved = ALPHA / DIGIT / "-" / "." / "_" / "~"
    public static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func isValid(_ verifier: String) -> Bool {
        (43...128).contains(verifier.count)
            && verifier.unicodeScalars.allSatisfy { unreserved.contains($0) }
    }

    private static func randomVerifier(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: max(32, byteCount))
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // SecRandomCopyBytes has no documented failure mode on Darwin; fall back to
            // the system RNG rather than shipping a predictable verifier.
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<bytes.count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Data(bytes).base64URLEncodedString()
    }
}

extension Data {
    /// base64url, unpadded (RFC 4648 §5) — the encoding every OAuth/PKCE value uses.
    nonisolated func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
