import XCTest
@testable import MyHealth

final class PKCETests: XCTestCase {
    /// Reference verifier from RFC 7636 Appendix B.
    /// verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    /// challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    func testKnownVerifierMatchesChallenge() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = PKCE.challenge(for: verifier)
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedVerifierLengthInRange() {
        for _ in 0..<10 {
            let v = PKCE.generateVerifier()
            XCTAssertGreaterThanOrEqual(v.count, 43)
            XCTAssertLessThanOrEqual(v.count, 128)
        }
    }

    func testGeneratedVerifierIsBase64URL() {
        let v = PKCE.generateVerifier()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(v.unicodeScalars.allSatisfy { allowed.contains($0) },
                      "verifier contains forbidden characters: \(v)")
    }

    func testChallengeIsDeterministic() {
        let v = "test-verifier-test-verifier-test-verifier-1"
        XCTAssertEqual(PKCE.challenge(for: v), PKCE.challenge(for: v))
    }
}
