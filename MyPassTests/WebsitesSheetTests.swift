import XCTest
@testable import MyPass

final class WebsitesSheetTests: XCTestCase {
    func testNormalizedURLsTrimsWhitespaceAndDropsBlankRows() {
        let result = WebsitesSheet.normalizedURLs(from: ["  https://a.example.com  ", "", "   ", "https://b.example.com"])
        XCTAssertEqual(result, ["https://a.example.com", "https://b.example.com"])
    }

    func testNormalizedURLsWithAllBlankRowsIsEmpty() {
        XCTAssertEqual(WebsitesSheet.normalizedURLs(from: ["", "  "]), [])
    }

    func testNormalizedURLsPreservesOrder() {
        XCTAssertEqual(
            WebsitesSheet.normalizedURLs(from: ["https://z.example.com", "https://a.example.com"]),
            ["https://z.example.com", "https://a.example.com"]
        )
    }
}
