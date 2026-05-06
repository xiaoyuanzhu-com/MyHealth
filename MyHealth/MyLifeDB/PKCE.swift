import Foundation
import CryptoKit

/// PKCE (RFC 7636) helpers used by the MyLifeDB Connect flow.
/// MyLifeDB requires `S256` and rejects `plain`.
enum PKCE {
    /// Generates a 64-byte verifier (well within the 43–128 char range
    /// required by RFC 7636 once base64url-encoded).
    static func generateVerifier() -> String {
        let bytes = (0..<64).map { _ in UInt8.random(in: .min ... .max) }
        return base64url(Data(bytes))
    }

    /// `base64url(SHA256(verifier))`, no padding.
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64url(Data(digest))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// CSRF state — also doubles as a sanity check against the redirect.
    static func generateState() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        return base64url(Data(bytes))
    }
}
