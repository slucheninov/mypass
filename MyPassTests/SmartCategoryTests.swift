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
        XCTAssertEqual(SmartCategory.all.title, "All")
        XCTAssertEqual(SmartCategory.favorites.title, "Favorites")
        XCTAssertEqual(SmartCategory.codes.title, "Codes")
        XCTAssertEqual(SmartCategory.passkeys.title, "Passkeys")
        XCTAssertEqual(SmartCategory.cards.title, "Cards")
        XCTAssertEqual(SmartCategory.notes.title, "Notes")
        XCTAssertEqual(SmartCategory.security.title, "Security")
        XCTAssertEqual(SmartCategory.deleted.title, "Deleted")
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
