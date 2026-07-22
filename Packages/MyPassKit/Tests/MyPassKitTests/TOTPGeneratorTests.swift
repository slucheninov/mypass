import XCTest
@testable import MyPassKit

final class TOTPGeneratorTests: XCTestCase {
    // RFC 6238 Appendix B, Test Vectors, Time=59, T0=0, X=30, SHA1, 8 digits.
    func testRFC6238SHA1VectorAtTime59() {
        let secret = Data("12345678901234567890".utf8)
        let time = Date(timeIntervalSince1970: 59)
        let code = TOTPGenerator.generate(secret: secret, time: time, step: 30, digits: 8, algorithm: .sha1)
        XCTAssertEqual(code, "94287082")
    }

    // RFC 6238 Appendix B, Time=1111111109, SHA1, 8 digits → 07081804.
    func testRFC6238SHA1VectorAtTime1111111109() {
        let secret = Data("12345678901234567890".utf8)
        let time = Date(timeIntervalSince1970: 1_111_111_109)
        let code = TOTPGenerator.generate(secret: secret, time: time, step: 30, digits: 8, algorithm: .sha1)
        XCTAssertEqual(code, "07081804")
    }

    // RFC 6238 Appendix B, Time=1111111111, SHA1, 8 digits → 14050471.
    func testRFC6238SHA1VectorAtTime1111111111() {
        let secret = Data("12345678901234567890".utf8)
        let time = Date(timeIntervalSince1970: 1_111_111_111)
        let code = TOTPGenerator.generate(secret: secret, time: time, step: 30, digits: 8, algorithm: .sha1)
        XCTAssertEqual(code, "14050471")
    }

    // RFC 6238 Appendix B, Time=59, SHA256, secret 32 bytes "12345678901234567890123456789012", 8 digits → 46119246.
    func testRFC6238SHA256VectorAtTime59() {
        let secret = Data("12345678901234567890123456789012".utf8)
        let time = Date(timeIntervalSince1970: 59)
        let code = TOTPGenerator.generate(secret: secret, time: time, step: 30, digits: 8, algorithm: .sha256)
        XCTAssertEqual(code, "46119246")
    }

    // RFC 6238 Appendix B, Time=1111111109, SHA256, 8 digits → 68084774.
    func testRFC6238SHA256VectorAtTime1111111109() {
        let secret = Data("12345678901234567890123456789012".utf8)
        let time = Date(timeIntervalSince1970: 1_111_111_109)
        let code = TOTPGenerator.generate(secret: secret, time: time, step: 30, digits: 8, algorithm: .sha256)
        XCTAssertEqual(code, "68084774")
    }

    // RFC 6238 Appendix B, Time=59, SHA512, secret 64 bytes "1234567890" repeated (+"1234"), 8 digits → 90693936.
    func testRFC6238SHA512VectorAtTime59() {
        let secret = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)
        let time = Date(timeIntervalSince1970: 59)
        let code = TOTPGenerator.generate(secret: secret, time: time, step: 30, digits: 8, algorithm: .sha512)
        XCTAssertEqual(code, "90693936")
    }

    // RFC 6238 Appendix B, Time=1111111109, SHA512, 8 digits → 25091201.
    func testRFC6238SHA512VectorAtTime1111111109() {
        let secret = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)
        let time = Date(timeIntervalSince1970: 1_111_111_109)
        let code = TOTPGenerator.generate(secret: secret, time: time, step: 30, digits: 8, algorithm: .sha512)
        XCTAssertEqual(code, "25091201")
    }

    func testDefaultSixDigitTruncation() {
        let secret = Data("12345678901234567890".utf8)
        let time = Date(timeIntervalSince1970: 59)
        let code = TOTPGenerator.generate(secret: secret, time: time, step: 30, digits: 6, algorithm: .sha1)
        XCTAssertEqual(code.count, 6)
        XCTAssertEqual(code, "287082") // last 6 digits of the 8-digit 94287082
    }
}
