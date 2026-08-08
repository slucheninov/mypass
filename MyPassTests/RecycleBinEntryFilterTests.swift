import XCTest
import MyPassKit
@testable import MyPass

final class RecycleBinEntryFilterTests: XCTestCase {
    private func makeEntry(title: String) -> KdbxEntry {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: []
        )
        entry.title = title
        return entry
    }

    private func makeGroup(name: String, entries: [KdbxEntry] = [], subgroups: [KdbxGroup] = []) -> KdbxGroup {
        let now = Date()
        return KdbxGroup(uuid: UUID(), name: name, iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: entries, subgroups: subgroups)
    }

    func testIsInRecycleBinTrueForEntryDirectlyInBin() {
        let entry = makeEntry(title: "Direct")
        let root = makeGroup(name: "Root")
        var db = KdbxDatabase(rootGroup: root, deletedObjects: [])
        let bin = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &db.recycleBinGroupUUID)
        bin.entries.append(entry)

        XCTAssertTrue(RecycleBinEntryFilter.isInRecycleBin(entry, database: db))
    }

    /// A future sync peer or third-party .kdbx import could nest an entry inside a
    /// subgroup of the bin rather than directly in `bin.entries`. It must still be
    /// recognized as deleted, otherwise it leaks back through every consumer of
    /// `isInRecycleBin` (extension bridge matching, smart-category filters/counts).
    func testIsInRecycleBinTrueForEntryNestedInBinSubgroup() {
        let entry = makeEntry(title: "Nested")
        let root = makeGroup(name: "Root")
        var db = KdbxDatabase(rootGroup: root, deletedObjects: [])
        let bin = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &db.recycleBinGroupUUID)
        let stray = makeGroup(name: "Stray", entries: [entry])
        bin.subgroups.append(stray)

        XCTAssertTrue(
            RecycleBinEntryFilter.isInRecycleBin(entry, database: db),
            "entries nested in a bin subgroup must still count as deleted"
        )
    }

    func testIsInRecycleBinFalseForLiveEntry() {
        let entry = makeEntry(title: "Live")
        let root = makeGroup(name: "Root", entries: [entry])
        var db = KdbxDatabase(rootGroup: root, deletedObjects: [])
        _ = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &db.recycleBinGroupUUID)

        XCTAssertFalse(RecycleBinEntryFilter.isInRecycleBin(entry, database: db))
    }
}
