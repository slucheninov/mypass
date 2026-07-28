import XCTest
@testable import MyPass

final class EntryURLDisplayTests: XCTestCase {
    func testDomainStripsSchemePathAndQuery() {
        XCTAssertEqual(EntryURLDisplay.domain(from: "https://login.example.com/path?q=1"), "example.com")
    }

    func testDomainFromBareHostWithoutScheme() {
        // Naive last-two-labels heuristic (documented limitation, no PSL support):
        // a multi-part suffix like "co.uk" collapses instead of preserving "example.co.uk".
        XCTAssertEqual(EntryURLDisplay.domain(from: "example.co.uk"), "co.uk")
    }

    func testDomainFromEmptyStringIsNil() {
        XCTAssertNil(EntryURLDisplay.domain(from: ""))
    }
}
