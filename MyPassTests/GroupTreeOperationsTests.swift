import XCTest
import MyPassKit
@testable import MyPass

final class GroupTreeOperationsTests: XCTestCase {
    func makeGroup(name: String, entries: [KdbxEntry] = [], subgroups: [KdbxGroup] = []) -> KdbxGroup {
        let now = Date()
        return KdbxGroup(uuid: UUID(), name: name, iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: entries, subgroups: subgroups)
    }

    func testAddSubgroupAppendsAndReturnsNewGroup() {
        let root = makeGroup(name: "Root")
        let created = GroupTreeOperations.addSubgroup(named: "Work", to: root)
        XCTAssertEqual(root.subgroups.count, 1)
        XCTAssertEqual(root.subgroups.first?.uuid, created.uuid)
        XCTAssertEqual(created.name, "Work")
    }

    func testRemoveSubgroupFindsNestedGroupAndRemovesIt() {
        let grandchild = makeGroup(name: "Grandchild")
        let child = makeGroup(name: "Child", subgroups: [grandchild])
        let root = makeGroup(name: "Root", subgroups: [child])

        let removed = GroupTreeOperations.removeSubgroup(withID: grandchild.uuid, from: root)
        XCTAssertTrue(removed)
        XCTAssertEqual(child.subgroups.count, 0)
    }

    func testRemoveSubgroupReturnsFalseWhenNotFound() {
        let root = makeGroup(name: "Root")
        XCTAssertFalse(GroupTreeOperations.removeSubgroup(withID: UUID(), from: root))
    }

    func testMoveEntryRelocatesFromSourceToDestination() {
        let now = Date()
        let entry = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: [])
        let source = makeGroup(name: "Source", entries: [entry])
        let destination = makeGroup(name: "Destination")
        let root = makeGroup(name: "Root", subgroups: [source, destination])

        let moved = GroupTreeOperations.moveEntry(withID: entry.uuid, to: destination.uuid, in: root)
        XCTAssertTrue(moved)
        XCTAssertEqual(source.entries.count, 0)
        XCTAssertEqual(destination.entries.first?.uuid, entry.uuid)
    }

    func testMoveEntryReturnsFalseWhenEntryNotFound() {
        let destination = makeGroup(name: "Destination")
        let root = makeGroup(name: "Root", subgroups: [destination])
        XCTAssertFalse(GroupTreeOperations.moveEntry(withID: UUID(), to: destination.uuid, in: root))
    }
}
