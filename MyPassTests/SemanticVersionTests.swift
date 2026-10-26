import XCTest
@testable import MyPass

final class SemanticVersionTests: XCTestCase {
    func testParsesPlainVersion() {
        XCTAssertEqual(SemanticVersion(string: "0.2.0"), SemanticVersion(major: 0, minor: 2, patch: 0))
    }

    func testParsesLeadingV() {
        let version = SemanticVersion(string: "v0.10.1")
        XCTAssertEqual(version, SemanticVersion(major: 0, minor: 10, patch: 1))
        XCTAssertEqual(version?.description, "0.10.1")
    }

    func testRejectsMalformedInput() {
        let malformed = [
            "0.2",
            "0.2.0-beta",
            "abc",
            "",
            "v",
            "vv1.2.3",
            "1.2.3.4",
            "+1.2.3",
            "1.-2.3",
            " 1.2.3",
            "1.2.3\n",
            "1.2.99999999999999999999"
        ]
        for input in malformed {
            XCTAssertNil(SemanticVersion(string: input), "expected nil for \(input.debugDescription)")
        }
    }

    func testOrdering() {
        let pairs = [
            ("0.2.0", "0.2.1"),
            ("0.2.1", "0.10.0"),
            ("0.10.0", "1.0.0")
        ]
        for (lower, higher) in pairs {
            XCTAssertLessThan(SemanticVersion(string: lower)!, SemanticVersion(string: higher)!)
        }
        XCTAssertLessThan(SemanticVersion(string: "0.2.0")!, SemanticVersion(string: "1.0.0")!)
        XCTAssertEqual(SemanticVersion(string: "v1.0.0"), SemanticVersion(string: "1.0.0"))
    }
}
