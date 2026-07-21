import XCTest
@testable import MyPassKit

final class KdbxModelTests: XCTestCase {
    func testEntryHistoryStoresPastVersionsWithoutNestedHistory() {
        let past = KdbxEntry(
            uuid: UUID(), iconID: 0,
            fields: [KdbxField(key: "Password", value: "old-pass", isProtected: true)],
            creationTime: Date(timeIntervalSince1970: 0),
            lastModificationTime: Date(timeIntervalSince1970: 100),
            lastAccessTime: Date(timeIntervalSince1970: 100),
            locationChanged: Date(timeIntervalSince1970: 0),
            history: []
        )
        let current = KdbxEntry(
            uuid: past.uuid, iconID: 0,
            fields: [KdbxField(key: "Password", value: "new-pass", isProtected: true)],
            creationTime: Date(timeIntervalSince1970: 0),
            lastModificationTime: Date(timeIntervalSince1970: 200),
            lastAccessTime: Date(timeIntervalSince1970: 200),
            locationChanged: Date(timeIntervalSince1970: 0),
            history: [past]
        )

        XCTAssertEqual(current.history.count, 1)
        XCTAssertEqual(current.history[0].fields.first?.value, "old-pass")
        XCTAssertTrue(current.history[0].history.isEmpty)
    }

    func testGroupTreeHoldsEntriesAndSubgroups() {
        let entry = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: Date(), lastModificationTime: Date(), lastAccessTime: Date(), locationChanged: Date(), history: [])
        let child = KdbxGroup(uuid: UUID(), name: "Work", iconID: 1, creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(), entries: [entry], subgroups: [])
        let root = KdbxGroup(uuid: UUID(), name: "Root", iconID: 0, creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(), entries: [], subgroups: [child])

        XCTAssertEqual(root.subgroups.count, 1)
        XCTAssertEqual(root.subgroups[0].entries.count, 1)
        XCTAssertEqual(root.subgroups[0].name, "Work")
    }

    func testDeletedObjectStoresUuidAndTimestamp() {
        let uuid = UUID()
        let deletionTime = Date(timeIntervalSince1970: 12345)
        let deleted = KdbxDeletedObject(uuid: uuid, deletionTime: deletionTime)

        XCTAssertEqual(deleted.uuid, uuid)
        XCTAssertEqual(deleted.deletionTime, deletionTime)
    }
}
