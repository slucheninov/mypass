import XCTest
@testable import MyPass

final class SmartCategoryTests: XCTestCase {
    func testAllCasesPresent() {
        XCTAssertEqual(
            Set(SmartCategory.allCases.map(\.rawValue)),
            Set(["all", "favorites", "codes", "security", "deleted"])
        )
    }

    func testTitles() {
        XCTAssertEqual(SmartCategory.all.title, "All")
        XCTAssertEqual(SmartCategory.favorites.title, "Favorites")
        XCTAssertEqual(SmartCategory.codes.title, "Codes")
        XCTAssertEqual(SmartCategory.security.title, "Security")
        XCTAssertEqual(SmartCategory.deleted.title, "Deleted")
    }

    func testPlaceholderCounts() {
        XCTAssertEqual(SmartCategory.all.placeholderCount, "58")
        XCTAssertEqual(SmartCategory.favorites.placeholderCount, "0")
        XCTAssertEqual(SmartCategory.codes.placeholderCount, "15")
        XCTAssertEqual(SmartCategory.security.placeholderCount, "—")
        XCTAssertEqual(SmartCategory.deleted.placeholderCount, "0")
    }

    func testIdentifiableUsesRawValue() {
        for category in SmartCategory.allCases {
            XCTAssertEqual(category.id, category.rawValue)
        }
    }
}
