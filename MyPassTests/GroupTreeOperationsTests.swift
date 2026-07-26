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

    /// Proves that once a real bin's identity is tracked via
    /// `recycleBinGroupUUID`, that tracked UUID takes priority over any
    /// later name-only match. (Superseded by the legacy-file name-fallback
    /// fix below: an *untracked* name match is now deliberately adopted as
    /// the bin — see `testRecycleBinGroupAdoptsPreExistingNameMatchWhenUUIDUntracked`
    /// — but a *tracked* UUID must still win over a same-named decoy that
    /// shows up afterwards.)
    func testRecycleBinGroupPrefersTrackedUUIDOverLaterNameOnlyDecoy() {
        let root = makeGroup(name: "Root")
        var recycleBinUUID: UUID? = nil
        let realBin = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &recycleBinUUID)

        // Decoy: a second group happens to share the bin's name, added
        // directly via addSubgroup (bypassing recycleBinGroup) after the
        // real bin's UUID is already tracked.
        let decoy = GroupTreeOperations.addSubgroup(named: GroupTreeOperations.recycleBinGroupName, to: root)

        let resolved = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &recycleBinUUID)

        XCTAssertEqual(resolved.uuid, realBin.uuid, "tracked UUID must take priority over any later name-only match")
        XCTAssertNotEqual(resolved.uuid, decoy.uuid)
        XCTAssertEqual(root.subgroups.count, 2, "no additional bin created; the decoy remains a separate, untouched group")
        XCTAssertEqual(recycleBinUUID, realBin.uuid)
    }

    /// Proves the legacy-file name fallback: a foreign/legacy file that already
    /// has a "Recycle Bin" group but no tracked `recycleBinGroupUUID` (e.g. a
    /// KeePassXC-written file, or a MyPass file saved before RecycleBinUUID
    /// existed) must have that pre-existing group adopted as the real bin,
    /// not have a second, orphaned "Recycle Bin" created alongside it.
    func testRecycleBinGroupAdoptsPreExistingNameMatchWhenUUIDUntracked() {
        let root = makeGroup(name: "Root")
        // Simulates a legacy/foreign file: the group already exists directly
        // under root, but was never registered via recycleBinGroup, so
        // recycleBinGroupUUID starts out nil.
        let existingBin = GroupTreeOperations.addSubgroup(named: GroupTreeOperations.recycleBinGroupName, to: root)

        var recycleBinUUID: UUID? = nil
        let resolved = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &recycleBinUUID)

        XCTAssertEqual(resolved.uuid, existingBin.uuid, "must adopt the pre-existing name-matched group instead of creating a new one")
        XCTAssertEqual(root.subgroups.count, 1, "no second bin group should be created")
        XCTAssertEqual(recycleBinUUID, existingBin.uuid, "recycleBinGroupUUID must now track the adopted group")
    }

    /// Proves backward compatibility with vaults that still use the pre-English
    /// Russian recycle bin group name.
    func testRecycleBinGroupAdoptsLegacyRussianNameWhenUUIDUntracked() {
        let root = makeGroup(name: "Root")
        let existingBin = GroupTreeOperations.addSubgroup(named: GroupTreeOperations.legacyRecycleBinGroupName, to: root)

        var recycleBinUUID: UUID? = nil
        let resolved = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &recycleBinUUID)

        XCTAssertEqual(resolved.uuid, existingBin.uuid)
        XCTAssertEqual(root.subgroups.count, 1)
        XCTAssertEqual(recycleBinUUID, existingBin.uuid)
        XCTAssertEqual(existingBin.name, GroupTreeOperations.legacyRecycleBinGroupName)
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
        let bin = root.subgroups.first { GroupTreeOperations.isRecycleBinGroup($0) }
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
        let bin = root.subgroups.first { GroupTreeOperations.isRecycleBinGroup($0) }
        let deletedEntry = bin?.entries.first { $0.uuid == entry.uuid }
        XCTAssertNotNil(deletedEntry)
        XCTAssertNotEqual(deletedEntry?.locationChanged, originalLocationChanged, "locationChanged must be updated when entry is soft-deleted into the recycle bin")
        XCTAssertGreaterThan(deletedEntry!.locationChanged, originalLocationChanged)
    }
}
