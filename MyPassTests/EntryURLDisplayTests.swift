import XCTest
@testable import MyPass

final class EntryURLDisplayTests: XCTestCase {
    func testDomainStripsSchemePathAndQuery() {
        XCTAssertEqual(EntryURLDisplay.domain(from: "https://login.example.com/path?q=1"), "example.com")
    }

    func testDomainFromBareHostWithoutScheme() {
        // PSL-correct: "co.uk" is a multi-label public suffix, so
        // "example.co.uk" is preserved whole rather than collapsing to "co.uk".
        XCTAssertEqual(EntryURLDisplay.domain(from: "example.co.uk"), "example.co.uk")
    }

    func testDomainFromEmptyStringIsNil() {
        XCTAssertNil(EntryURLDisplay.domain(from: ""))
    }
}
