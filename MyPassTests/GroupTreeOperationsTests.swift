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

    func testRecycleBinGroupCreatesItOnFirstAccess() {
        let root = makeGroup(name: "Root")
        var recycleBinUUID: UUID? = nil
        let bin = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &recycleBinUUID)
        XCTAssertEqual(bin.name, GroupTreeOperations.recycleBinGroupName)
        XCTAssertEqual(root.subgroups.count, 1)
        XCTAssertEqual(recycleBinUUID, bin.uuid)
    }

    func testRecycleBinGroupReturnsExistingOneOnSecondAccess() {
        let root = makeGroup(name: "Root")
        var recycleBinUUID: UUID? = nil
        let first = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &recycleBinUUID)
        let second = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &recycleBinUUID)
        XCTAssertEqual(first.uuid, second.uuid)
        XCTAssertEqual(root.subgroups.count, 1)
    }

    /// Proves the fix for the identity-confusion bug: a decoy group that happens
    /// to share the recycle bin's display name (but was never registered as the
    /// bin via `recycleBinGroupUUID`) must NOT be mistaken for the real bin.
    /// `recycleBinGroup` must track identity via `recycleBinGroupUUID`, not by
    /// matching `name == recycleBinGroupName` against `root.subgroups` (the old,
    /// buggy behavior this test would have failed against).
    func testRecycleBinGroupIgnoresNameOnlyDecoyAndTracksRealBinByUUID() {
        let root = makeGroup(name: "Root")
        // Decoy: created directly via addSubgroup, bypassing recycleBinGroup, so
        // it is never registered in recycleBinGroupUUID despite sharing the name.
        let decoy = GroupTreeOperations.addSubgroup(named: GroupTreeOperations.recycleBinGroupName, to: root)

        var recycleBinUUID: UUID? = nil
        let realBin = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &recycleBinUUID)

        XCTAssertNotEqual(realBin.uuid, decoy.uuid, "must create its own real bin, not mistake the name-only decoy for it")
        XCTAssertEqual(root.subgroups.count, 2, "both the decoy and the newly created real bin should exist as separate groups")
        XCTAssertEqual(recycleBinUUID, realBin.uuid)

        // A second call, now that recycleBinGroupUUID is set, must return the
        // real bin again — not the decoy — even though both share the name.
        let secondCall = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &recycleBinUUID)
        XCTAssertEqual(secondCall.uuid, realBin.uuid)
        XCTAssertNotEqual(secondCall.uuid, decoy.uuid)
        XCTAssertEqual(root.subgroups.count, 2, "second call must not create yet another bin")
    }

    func testSoftDeleteMovesEntryToRecycleBinAndRecordsDeletedObject() {
        let now = Date()
        let entry = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: [])
        let source = makeGroup(name: "Source", entries: [entry])
        let root = makeGroup(name: "Root", subgroups: [source])
        var deletedObjects: [KdbxDeletedObject] = []
        var recycleBinUUID: UUID? = nil

        let deleted = GroupTreeOperations.softDeleteEntry(withID: entry.uuid, in: root, deletedObjects: &deletedObjects, recycleBinGroupUUID: &recycleBinUUID)

        XCTAssertTrue(deleted)
        XCTAssertEqual(source.entries.count, 0)
        let bin = root.subgroups.first { $0.name == GroupTreeOperations.recycleBinGroupName }
        XCTAssertEqual(bin?.entries.first?.uuid, entry.uuid)
        XCTAssertEqual(deletedObjects.count, 1)
        XCTAssertEqual(deletedObjects.first?.uuid, entry.uuid)
        XCTAssertEqual(recycleBinUUID, bin?.uuid)
    }

    func testRestoreEntryMovesFromRecycleBinBackToDestination() {
        let now = Date()
        let entry = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: [])
        let source = makeGroup(name: "Source", entries: [entry])
        let root = makeGroup(name: "Root", subgroups: [source])
        var deletedObjects: [KdbxDeletedObject] = []
        var recycleBinUUID: UUID? = nil
        GroupTreeOperations.softDeleteEntry(withID: entry.uuid, in: root, deletedObjects: &deletedObjects, recycleBinGroupUUID: &recycleBinUUID)

        let restored = GroupTreeOperations.restoreEntry(withID: entry.uuid, to: source.uuid, in: root)

        XCTAssertTrue(restored)
        XCTAssertEqual(source.entries.first?.uuid, entry.uuid)
    }

    /// Proves the locationChanged fix: `moveEntry` must update the moved
    /// entry's OWN `locationChanged` field, not just the surrounding groups'
    /// `lastModificationTime`. Before the fix, the entry landing in the
    /// destination group would still carry its original (pre-move)
    /// `locationChanged` value.
    func testMoveEntryUpdatesEntryLocationChanged() {
        let originalLocationChanged = Date(timeIntervalSince1970: 1_000_000)
        let entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: originalLocationChanged, lastModificationTime: originalLocationChanged,
            lastAccessTime: originalLocationChanged, locationChanged: originalLocationChanged, history: []
        )
        let source = makeGroup(name: "Source", entries: [entry])
        let destination = makeGroup(name: "Destination")
        let root = makeGroup(name: "Root", subgroups: [source, destination])

        let moved = GroupTreeOperations.moveEntry(withID: entry.uuid, to: destination.uuid, in: root)

        XCTAssertTrue(moved)
        let movedEntry = destination.entries.first { $0.uuid == entry.uuid }
        XCTAssertNotNil(movedEntry)
        XCTAssertNotEqual(movedEntry?.locationChanged, originalLocationChanged, "locationChanged must be updated to the time of the move")
        XCTAssertGreaterThan(movedEntry!.locationChanged, originalLocationChanged)
    }

    /// Same as above, for `softDeleteEntry`: the entry landing in the recycle
    /// bin must have its `locationChanged` updated to reflect the move into
    /// the bin, since the format reserves this field specifically to track
    /// "when did this entry move to a different group" (which the recycle
    /// bin counts as).
    func testSoftDeleteEntryUpdatesEntryLocationChanged() {
        let originalLocationChanged = Date(timeIntervalSince1970: 1_000_000)
        let entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: originalLocationChanged, lastModificationTime: originalLocationChanged,
            lastAccessTime: originalLocationChanged, locationChanged: originalLocationChanged, history: []
        )
        let source = makeGroup(name: "Source", entries: [entry])
        let root = makeGroup(name: "Root", subgroups: [source])
        var deletedObjects: [KdbxDeletedObject] = []
        var recycleBinUUID: UUID? = nil

        let deleted = GroupTreeOperations.softDeleteEntry(withID: entry.uuid, in: root, deletedObjects: &deletedObjects, recycleBinGroupUUID: &recycleBinUUID)

        XCTAssertTrue(deleted)
        let bin = root.subgroups.first { $0.name == GroupTreeOperations.recycleBinGroupName }
        let deletedEntry = bin?.entries.first { $0.uuid == entry.uuid }
        XCTAssertNotNil(deletedEntry)
        XCTAssertNotEqual(deletedEntry?.locationChanged, originalLocationChanged, "locationChanged must be updated when entry is soft-deleted into the recycle bin")
        XCTAssertGreaterThan(deletedEntry!.locationChanged, originalLocationChanged)
    }
}
