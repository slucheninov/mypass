import XCTest
import MyPassKit

final class URIMatchModeTests: XCTestCase {
    func testRawValuesAreKebabCase() {
        XCTAssertEqual(URIMatchMode.registrableDomain.rawValue, "registrable-domain")
        XCTAssertEqual(URIMatchMode.host.rawValue, "host")
        XCTAssertEqual(URIMatchMode.startsWith.rawValue, "starts-with")
        XCTAssertEqual(URIMatchMode.exact.rawValue, "exact")
        XCTAssertEqual(URIMatchMode.never.rawValue, "never")
    }

    func testAllCasesCoversEveryModeExactlyOnce() {
        XCTAssertEqual(URIMatchMode.allCases.count, 5)
        XCTAssertEqual(Set(URIMatchMode.allCases).count, 5)
    }
}
