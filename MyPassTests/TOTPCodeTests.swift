import XCTest
import MyPassKit
@testable import MyPass

final class TOTPCodeTests: XCTestCase {
    func testBase32RoundTrip() {
        let original = Data("Hello!!".utf8)
        let encoded = TOTPCode.base32Encode(original)
        let decoded = TOTPCode.base32Decode(encoded)
        XCTAssertEqual(decoded, original)
    }

    func testBase32DecodeKnownVector() {
        // RFC 4648 test vector: "foobar" -> "MZXW6YTBOI======"
        let decoded = TOTPCode.base32Decode("MZXW6YTBOI======")
        XCTAssertEqual(decoded, Data("foobar".utf8))
    }

    func testParseOtpauthURLExtractsSecretDigitsPeriodAlgorithm() {
        // secret "JBSWY3DPEHPK3PXP" decodes to "Hello!\xDE\xAD\xBE\xEF"-ish bytes (RFC 6238-style example issuer/account)
        let url = "otpauth://totp/Example:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example&algorithm=SHA1&digits=6&period=30"
        guard let parsed = TOTPCode.parse(otpauthURL: url) else {
            return XCTFail("expected successful parse")
        }
        XCTAssertEqual(parsed.secret, TOTPCode.base32Decode("JBSWY3DPEHPK3PXP"))
        XCTAssertEqual(parsed.digits, 6)
        XCTAssertEqual(parsed.period, 30)
        XCTAssertEqual(parsed.algorithm, .sha1)
    }

    func testParseOtpauthURLDefaultsWhenParamsMissing() {
        let url = "otpauth://totp/Example:alice@example.com?secret=JBSWY3DPEHPK3PXP"
        guard let parsed = TOTPCode.parse(otpauthURL: url) else {
            return XCTFail("expected successful parse")
        }
        XCTAssertEqual(parsed.digits, 6)
        XCTAssertEqual(parsed.period, 30)
        XCTAssertEqual(parsed.algorithm, .sha1)
    }

    func testParseOtpauthURLReturnsNilWithoutSecret() {
        let url = "otpauth://totp/Example:alice@example.com?issuer=Example"
        XCTAssertNil(TOTPCode.parse(otpauthURL: url))
    }

    func testCurrentCodeMatchesUnderlyingGeneratorAtFixedTime() {
        let secretBase32 = TOTPCode.base32Encode(Data([0x01, 0x02, 0x03, 0x04, 0x05]))
        let now = Date(timeIntervalSince1970: 59)
        let expected = TOTPGenerator.generate(
            secret: Data([0x01, 0x02, 0x03, 0x04, 0x05]),
            time: now,
            step: 30,
            digits: 6,
            algorithm: .sha1
        )
        let actual = TOTPCode.currentCode(secretBase32: secretBase32, digits: 6, period: 30, algorithm: .sha1, now: now)
        XCTAssertEqual(actual, expected)
    }

    func testCurrentCodeReturnsNilForInvalidBase32() {
        let actual = TOTPCode.currentCode(secretBase32: "not-valid-base32!!", digits: 6, period: 30, algorithm: .sha1, now: Date())
        XCTAssertNil(actual)
    }

    func testSecondsRemainingAtStartOfPeriod() {
        let now = Date(timeIntervalSince1970: 30) // exactly on a 30s boundary
        XCTAssertEqual(TOTPCode.secondsRemaining(period: 30, now: now), 30, accuracy: 0.001)
    }

    func testSecondsRemainingMidPeriod() {
        let now = Date(timeIntervalSince1970: 45) // 15s into the [30,60) window
        XCTAssertEqual(TOTPCode.secondsRemaining(period: 30, now: now), 15, accuracy: 0.001)
    }

    func testSecondsRemainingOneSecondBeforeBoundary() {
        let now = Date(timeIntervalSince1970: 59)
        XCTAssertEqual(TOTPCode.secondsRemaining(period: 30, now: now), 1, accuracy: 0.001)
    }
}
