import XCTest
import MyPassKit
@testable import MyPass

final class EntryHistoryOperationsTests: XCTestCase {
    func testRestoreVersionPushesCurrentStateToHistoryAndAppliesOldFields() {
        let now = Date()
        let earlier = now.addingTimeInterval(-3600)

        var oldVersion = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: earlier, lastModificationTime: earlier, lastAccessTime: earlier, locationChanged: earlier, history: [])
        oldVersion.title = "Old Title"
        oldVersion.password = "old-password"

        var entry = KdbxEntry(uuid: oldVersion.uuid, iconID: 0, fields: [], creationTime: earlier, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: [])
        entry.title = "New Title"
        entry.password = "new-password"

        EntryHistoryOperations.restoreVersion(oldVersion, into: &entry)

        XCTAssertEqual(entry.title, "Old Title")
        XCTAssertEqual(entry.password, "old-password")
        XCTAssertEqual(entry.history.count, 1)
        XCTAssertEqual(entry.history.first?.title, "New Title")
        XCTAssertEqual(entry.history.first?.history.count, 0)
    }

    func testClearHistoryRemovesAllVersions() {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now,
            history: []
        )
        var snapshot = entry
        snapshot.title = "Old"
        entry.history = [snapshot, snapshot]
        EntryHistoryOperations.clearHistory(on: &entry)
        XCTAssertTrue(entry.history.isEmpty)
    }
}
