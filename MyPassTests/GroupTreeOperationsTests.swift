import XCTest
import MyPassKit
@testable import MyPass

final class GroupTreeOperationsTests: XCTestCase {
    func makeGroup(name: String, entries: [KdbxEntry] = [], subgroups: [KdbxGroup] = []) -> KdbxGroup {
        let now = Date()
        return KdbxGroup(uuid: UUID(), name: name, iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: entries, subgroups: subgroups)
    }

    func testAddGroupAppendsToRootAndReturnsNewGroup() {
        let root = makeGroup(name: "Root")
        let created = GroupTreeOperations.addGroup(named: "Work", emoji: "💼", to: root)
        XCTAssertEqual(root.subgroups.count, 1)
        XCTAssertEqual(root.subgroups.first?.uuid, created.uuid)
        XCTAssertEqual(created.name, "Work")
        XCTAssertEqual(created.emoji, "💼")
    }

    func testAddGroupAlwaysLandsAtRootLevel() {
        let nested = makeGroup(name: "Nested")
        let child = makeGroup(name: "Child", subgroups: [nested])
        let root = makeGroup(name: "Root", subgroups: [child])

        let created = GroupTreeOperations.addGroup(named: "Flat", emoji: nil, to: root)

        XCTAssertEqual(root.subgroups.count, 2)
        XCTAssertTrue(root.subgroups.contains { $0.uuid == created.uuid })
        XCTAssertFalse(child.subgroups.contains { $0.uuid == created.uuid })
    }

    func testUpdateGroupRenamesAndSetsEmoji() {
        let work = makeGroup(name: "Work")
        let root = makeGroup(name: "Root", subgroups: [work])

        let updated = GroupTreeOperations.updateGroup(withID: work.uuid, name: "Personal", emoji: "🏠", in: root)

        XCTAssertTrue(updated)
        XCTAssertEqual(work.name, "Personal")
        XCTAssertEqual(work.emoji, "🏠")
    }

    func testUpdateGroupClearsEmoji() {
        var work = makeGroup(name: "Work")
        work.emoji = "💼"
        let root = makeGroup(name: "Root", subgroups: [work])

        let updated = GroupTreeOperations.updateGroup(withID: work.uuid, name: "Work", emoji: nil, in: root)

        XCTAssertTrue(updated)
        XCTAssertNil(work.emoji)
    }

    func testUpdateGroupFindsNestedLegacyGroup() {
        let nested = makeGroup(name: "Nested")
        let child = makeGroup(name: "Child", subgroups: [nested])
        let root = makeGroup(name: "Root", subgroups: [child])

        let updated = GroupTreeOperations.updateGroup(withID: nested.uuid, name: "Renamed", emoji: "🔐", in: root)

        XCTAssertTrue(updated)
        XCTAssertEqual(nested.name, "Renamed")
        XCTAssertEqual(nested.emoji, "🔐")
    }

    func testDeleteGroupMovesEntriesIncludingNestedOnesToRecycleBin() {
        let now = Date()
        let nestedEntry = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: [])
        let directEntry = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: [])
        let nested = makeGroup(name: "Nested", entries: [nestedEntry])
        let work = makeGroup(name: "Work", entries: [directEntry], subgroups: [nested])
        let root = makeGroup(name: "Root", subgroups: [work])
        var deletedObjects: [KdbxDeletedObject] = []
        var recycleBinUUID: UUID? = nil

        let deleted = GroupTreeOperations.deleteGroup(withID: work.uuid, in: root, deletedObjects: &deletedObjects, recycleBinGroupUUID: &recycleBinUUID)

        XCTAssertTrue(deleted)
        XCTAssertFalse(root.subgroups.contains { $0.uuid == work.uuid })
        let bin = root.subgroups.first { GroupTreeOperations.isRecycleBinGroup($0) }
        XCTAssertNotNil(bin)
        XCTAssertEqual(bin?.entries.count, 2)
        XCTAssertTrue(bin!.entries.contains { $0.uuid == directEntry.uuid })
        XCTAssertTrue(bin!.entries.contains { $0.uuid == nestedEntry.uuid })
        XCTAssertTrue(deletedObjects.contains { $0.uuid == work.uuid })
        XCTAssertTrue(deletedObjects.contains { $0.uuid == nested.uuid })
        XCTAssertTrue(deletedObjects.contains { $0.uuid == directEntry.uuid })
        XCTAssertTrue(deletedObjects.contains { $0.uuid == nestedEntry.uuid })
    }

    func testDeleteGroupRefusesToDeleteRecycleBin() {
        let root = makeGroup(name: "Root")
        var deletedObjects: [KdbxDeletedObject] = []
        var recycleBinUUID: UUID? = nil
        let bin = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &recycleBinUUID)

        let deleted = GroupTreeOperations.deleteGroup(withID: bin.uuid, in: root, deletedObjects: &deletedObjects, recycleBinGroupUUID: &recycleBinUUID)

        XCTAssertFalse(deleted)
        XCTAssertEqual(root.subgroups.count, 1)
    }

    func testDeleteGroupRefusesToDeleteRoot() {
        let root = makeGroup(name: "Root")
        var deletedObjects: [KdbxDeletedObject] = []
        var recycleBinUUID: UUID? = nil

        let deleted = GroupTreeOperations.deleteGroup(withID: root.uuid, in: root, deletedObjects: &deletedObjects, recycleBinGroupUUID: &recycleBinUUID)

        XCTAssertFalse(deleted)
    }

    func testDeleteGroupRemovesLegacyNestedSubgroupDirectly() {
        let now = Date()
        let entry = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: [])
        let nested = makeGroup(name: "Nested", entries: [entry])
        let child = makeGroup(name: "Child", subgroups: [nested])
        let root = makeGroup(name: "Root", subgroups: [child])
        var deletedObjects: [KdbxDeletedObject] = []
        var recycleBinUUID: UUID? = nil

        let deleted = GroupTreeOperations.deleteGroup(withID: nested.uuid, in: root, deletedObjects: &deletedObjects, recycleBinGroupUUID: &recycleBinUUID)

        XCTAssertTrue(deleted)
        XCTAssertEqual(child.subgroups.count, 0)
        XCTAssertTrue(root.subgroups.contains { $0.uuid == child.uuid })
        let bin = root.subgroups.first { GroupTreeOperations.isRecycleBinGroup($0) }
        XCTAssertEqual(bin?.entries.first?.uuid, entry.uuid)
        XCTAssertTrue(deletedObjects.contains { $0.uuid == nested.uuid })
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
        // directly via addGroup (bypassing recycleBinGroup) after the
        // real bin's UUID is already tracked.
        let decoy = GroupTreeOperations.addGroup(named: GroupTreeOperations.recycleBinGroupName, emoji: nil, to: root)

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
        let existingBin = GroupTreeOperations.addGroup(named: GroupTreeOperations.recycleBinGroupName, emoji: nil, to: root)

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
        let existingBin = GroupTreeOperations.addGroup(named: GroupTreeOperations.legacyRecycleBinGroupName, emoji: nil, to: root)

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

    func testClampedDefaultGroupIDReturnsRootWhenCandidateIsRecycleBinUUID() {
        let root = makeGroup(name: "Root")
        var recycleBinUUID: UUID? = nil
        let bin = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &recycleBinUUID)

        let clamped = GroupTreeOperations.clampedDefaultGroupID(bin.uuid, in: root, recycleBinGroupUUID: recycleBinUUID)

        XCTAssertEqual(clamped, root.uuid)
    }

    func testClampedDefaultGroupIDReturnsCandidateWhenNotRecycleBin() {
        let work = makeGroup(name: "Work")
        let root = makeGroup(name: "Root", subgroups: [work])
        var recycleBinUUID: UUID? = nil
        _ = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &recycleBinUUID)

        let clamped = GroupTreeOperations.clampedDefaultGroupID(work.uuid, in: root, recycleBinGroupUUID: recycleBinUUID)

        XCTAssertEqual(clamped, work.uuid)
    }

    func testClampedDefaultGroupIDFallsBackByNameWhenUUIDUntracked() {
        let root = makeGroup(name: "Root")
        let bin = GroupTreeOperations.addGroup(named: GroupTreeOperations.recycleBinGroupName, emoji: nil, to: root)

        let clamped = GroupTreeOperations.clampedDefaultGroupID(bin.uuid, in: root, recycleBinGroupUUID: nil)

        XCTAssertEqual(clamped, root.uuid)
    }

    func testSelectableGroupsExcludesRecycleBinButIncludesEverythingElse() {
        let recycleBin = KdbxGroup(
            uuid: UUID(), name: "Recycle Bin", iconID: 0,
            creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(),
            entries: [], subgroups: []
        )
        let child = KdbxGroup(
            uuid: UUID(), name: "Work", iconID: 0,
            creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(),
            entries: [], subgroups: []
        )
        let root = KdbxGroup(
            uuid: UUID(), name: "Root", iconID: 0,
            creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(),
            entries: [], subgroups: [child, recycleBin]
        )

        let selectable = GroupTreeOperations.selectableGroups(in: root, excludingRecycleBin: recycleBin.uuid)

        XCTAssertEqual(Set(selectable.map(\.uuid)), [root.uuid, child.uuid])
    }

    // MARK: - permanentlyDeleteEntry

    func testPermanentlyDeleteEntryRemovesAndTombstonesWithoutAddingToBin() {
        let now = Date()
        let entry = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: [])
        let source = makeGroup(name: "Source", entries: [entry])
        let root = makeGroup(name: "Root", subgroups: [source])
        var deletedObjects: [KdbxDeletedObject] = []

        let deleted = GroupTreeOperations.permanentlyDeleteEntry(withID: entry.uuid, in: root, deletedObjects: &deletedObjects)

        XCTAssertTrue(deleted)
        XCTAssertEqual(source.entries.count, 0)
        XCTAssertEqual(deletedObjects.count, 1)
        XCTAssertEqual(deletedObjects.first?.uuid, entry.uuid)
        XCTAssertNil(root.subgroups.first { GroupTreeOperations.isRecycleBinGroup($0) }, "must not create/add to a recycle bin")
    }

    func testPermanentlyDeleteEntryReturnsFalseWhenEntryNotFound() {
        let root = makeGroup(name: "Root")
        var deletedObjects: [KdbxDeletedObject] = []

        let deleted = GroupTreeOperations.permanentlyDeleteEntry(withID: UUID(), in: root, deletedObjects: &deletedObjects)

        XCTAssertFalse(deleted)
        XCTAssertTrue(deletedObjects.isEmpty)
    }

    // MARK: - emptyRecycleBin

    func testEmptyRecycleBinRemovesEntriesAndTombstonesButKeepsBinGroup() {
        let now = Date()
        let entry1 = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: [])
        let entry2 = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: [])
        let root = makeGroup(name: "Root")
        var recycleBinUUID: UUID? = nil
        let bin = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &recycleBinUUID)
        bin.entries.append(contentsOf: [entry1, entry2])
        var deletedObjects: [KdbxDeletedObject] = []

        GroupTreeOperations.emptyRecycleBin(in: root, deletedObjects: &deletedObjects, recycleBinGroupUUID: recycleBinUUID)

        XCTAssertEqual(bin.entries.count, 0)
        XCTAssertTrue(root.subgroups.contains { $0.uuid == bin.uuid }, "the bin group itself must stay")
        XCTAssertEqual(deletedObjects.count, 2)
        XCTAssertTrue(deletedObjects.contains { $0.uuid == entry1.uuid })
        XCTAssertTrue(deletedObjects.contains { $0.uuid == entry2.uuid })
    }

    func testEmptyRecycleBinRemovesStraySubgroupsAndTombstonesThem() {
        let now = Date()
        let nestedEntry = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: [])
        let stray = makeGroup(name: "Stray", entries: [nestedEntry])
        let root = makeGroup(name: "Root")
        var recycleBinUUID: UUID? = nil
        let bin = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &recycleBinUUID)
        bin.subgroups.append(stray)
        var deletedObjects: [KdbxDeletedObject] = []

        GroupTreeOperations.emptyRecycleBin(in: root, deletedObjects: &deletedObjects, recycleBinGroupUUID: recycleBinUUID)

        XCTAssertEqual(bin.subgroups.count, 0)
        XCTAssertTrue(deletedObjects.contains { $0.uuid == stray.uuid })
        XCTAssertTrue(deletedObjects.contains { $0.uuid == nestedEntry.uuid })
    }

    func testEmptyRecycleBinOnMissingBinIsSafeNoOp() {
        let root = makeGroup(name: "Root")
        var deletedObjects: [KdbxDeletedObject] = []

        GroupTreeOperations.emptyRecycleBin(in: root, deletedObjects: &deletedObjects, recycleBinGroupUUID: nil)

        XCTAssertTrue(deletedObjects.isEmpty)
    }

    func testEmptyRecycleBinOnEmptyBinIsSafeNoOp() {
        let root = makeGroup(name: "Root")
        var recycleBinUUID: UUID? = nil
        _ = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &recycleBinUUID)
        var deletedObjects: [KdbxDeletedObject] = []

        GroupTreeOperations.emptyRecycleBin(in: root, deletedObjects: &deletedObjects, recycleBinGroupUUID: recycleBinUUID)

        XCTAssertTrue(deletedObjects.isEmpty)
    }
}
