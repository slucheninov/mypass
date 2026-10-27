import XCTest
import MyPassKit
@testable import MyPass

final class SmartCategoryTests: XCTestCase {
    func testAllCasesPresent() {
        XCTAssertEqual(
            Set(SmartCategory.allCases.map(\.rawValue)),
            Set(["all", "favorites", "codes", "passkeys", "addresses", "cards", "notes", "security", "deleted"])
        )
    }

    func testTitles() {
        XCTAssertEqual(String(localized: SmartCategory.all.title), "All")
        XCTAssertEqual(String(localized: SmartCategory.favorites.title), "Favorites")
        XCTAssertEqual(String(localized: SmartCategory.codes.title), "Codes")
        XCTAssertEqual(String(localized: SmartCategory.passkeys.title), "Passkeys")
        XCTAssertEqual(String(localized: SmartCategory.cards.title), "Cards")
        XCTAssertEqual(String(localized: SmartCategory.notes.title), "Notes")
        XCTAssertEqual(String(localized: SmartCategory.security.title), "Security")
        XCTAssertEqual(String(localized: SmartCategory.deleted.title), "Deleted")
    }

    func testCountDisplayDelegatesToSmartCategoryCounts() throws {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: []
        )
        entry.title = "One"
        let root = KdbxGroup(
            uuid: UUID(), name: "Root", iconID: 0,
            creationTime: now, lastModificationTime: now, locationChanged: now,
            entries: [entry], subgroups: []
        )
        let db = KdbxDatabase(rootGroup: root, deletedObjects: [])
        XCTAssertEqual(SmartCategory.all.countDisplay(for: db), "1")
        XCTAssertEqual(SmartCategory.security.countDisplay(for: db), "—")
    }

    func testIdentifiableUsesRawValue() {
        for category in SmartCategory.allCases {
            XCTAssertEqual(category.id, category.rawValue)
        }
    }
}
