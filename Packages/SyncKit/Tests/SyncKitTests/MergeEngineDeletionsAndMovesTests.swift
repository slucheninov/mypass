import XCTest
import MyPassKit
@testable import SyncKit

private extension KdbxEntry {
    var title: String {
        fields.first(where: { $0.key == "Title" })?.value ?? ""
    }
}

final class MergeEngineDeletionsAndMovesTests: XCTestCase {
    func makeDatabase(
        rootUUID: UUID,
        rootModified: Date = Date(timeIntervalSince1970: 1_000),
        entries: [KdbxEntry] = [],
        subgroups: [KdbxGroup] = [],
        deletedObjects: [KdbxDeletedObject] = [],
        recycleBinGroupUUID: UUID? = nil
    ) -> KdbxDatabase {
        let root = KdbxGroup(
            uuid: rootUUID,
            name: "MyPass",
            iconID: 0,
            creationTime: rootModified,
            lastModificationTime: rootModified,
            locationChanged: rootModified,
            entries: entries,
            subgroups: subgroups
        )
        return KdbxDatabase(rootGroup: root, deletedObjects: deletedObjects, recycleBinGroupUUID: recycleBinGroupUUID)
    }

    func makeEntry(uuid: UUID, title: String, modified: Date, locationChanged: Date? = nil) -> KdbxEntry {
        var entry = KdbxEntry(
            uuid: uuid,
            iconID: 0,
            fields: [],
            creationTime: modified,
            lastModificationTime: modified,
            lastAccessTime: modified,
            locationChanged: locationChanged ?? modified,
            history: []
        )
        entry.fields = [KdbxField(key: "Title", value: title, isProtected: false)]
        return entry
    }

    // Rule 5: delete on one side + edit on the other, resurrection vs deletion-wins.

    func testDeleteLocalEditRemoteNewerResurrects() {
        let rootUUID = UUID()
        let entryUUID = UUID()
        // Local deleted the entry at t=2000.
        let local = makeDatabase(
            rootUUID: rootUUID,
            entries: [],
            deletedObjects: [KdbxDeletedObject(uuid: entryUUID, deletionTime: Date(timeIntervalSince1970: 2_000))]
        )
        // Remote edited it at t=3000 — newer than the deletion.
        let remoteEntry = makeEntry(uuid: entryUUID, title: "ResurrectedByRemote", modified: Date(timeIntervalSince1970: 3_000))
        let remote = makeDatabase(rootUUID: rootUUID, entries: [remoteEntry])

        let merged = MergeEngine.merge(local: local, remote: remote)

        XCTAssertEqual(merged.rootGroup.entries.count, 1)
        XCTAssertEqual(merged.rootGroup.entries.first?.uuid, entryUUID)
        XCTAssertFalse(merged.deletedObjects.contains { $0.uuid == entryUUID })
    }

    func testDeleteLocalEditRemoteOlderDeletionWins() {
        let rootUUID = UUID()
        let entryUUID = UUID()
        // Local deleted the entry at t=5000.
        let local = makeDatabase(
            rootUUID: rootUUID,
            entries: [],
            deletedObjects: [KdbxDeletedObject(uuid: entryUUID, deletionTime: Date(timeIntervalSince1970: 5_000))]
        )
        // Remote's edit at t=1000 predates the deletion.
        let remoteEntry = makeEntry(uuid: entryUUID, title: "StaleEdit", modified: Date(timeIntervalSince1970: 1_000))
        let remote = makeDatabase(rootUUID: rootUUID, entries: [remoteEntry])

        let merged = MergeEngine.merge(local: local, remote: remote)

        XCTAssertFalse(merged.rootGroup.entries.contains { $0.uuid == entryUUID })
        XCTAssertTrue(merged.deletedObjects.contains { $0.uuid == entryUUID })
    }

    func testDeleteRemoteEditLocalNewerResurrects() {
        let rootUUID = UUID()
        let entryUUID = UUID()
        let localEntry = makeEntry(uuid: entryUUID, title: "ResurrectedByLocal", modified: Date(timeIntervalSince1970: 3_000))
        let local = makeDatabase(rootUUID: rootUUID, entries: [localEntry])
        let remote = makeDatabase(
            rootUUID: rootUUID,
            entries: [],
            deletedObjects: [KdbxDeletedObject(uuid: entryUUID, deletionTime: Date(timeIntervalSince1970: 2_000))]
        )

        let merged = MergeEngine.merge(local: local, remote: remote)

        XCTAssertEqual(merged.rootGroup.entries.count, 1)
        XCTAssertEqual(merged.rootGroup.entries.first?.uuid, entryUUID)
        XCTAssertFalse(merged.deletedObjects.contains { $0.uuid == entryUUID })
    }

    func testDeleteRemoteEditLocalOlderDeletionWins() {
        let rootUUID = UUID()
        let entryUUID = UUID()
        let localEntry = makeEntry(uuid: entryUUID, title: "StaleEdit", modified: Date(timeIntervalSince1970: 1_000))
        let local = makeDatabase(rootUUID: rootUUID, entries: [localEntry])
        let remote = makeDatabase(
            rootUUID: rootUUID,
            entries: [],
            deletedObjects: [KdbxDeletedObject(uuid: entryUUID, deletionTime: Date(timeIntervalSince1970: 5_000))]
        )

        let merged = MergeEngine.merge(local: local, remote: remote)

        XCTAssertFalse(merged.rootGroup.entries.contains { $0.uuid == entryUUID })
        XCTAssertTrue(merged.deletedObjects.contains { $0.uuid == entryUUID })
    }

    // Rule 6: moves via locationChanged.

    func testMoveLocalNewerLocationWins() {
        let rootUUID = UUID()
        let folderAUUID = UUID()
        let folderBUUID = UUID()
        let entryUUID = UUID()

        let entryInA = makeEntry(uuid: entryUUID, title: "Moved", modified: Date(timeIntervalSince1970: 1_000), locationChanged: Date(timeIntervalSince1970: 1_000))
        let entryInB = makeEntry(uuid: entryUUID, title: "Moved", modified: Date(timeIntervalSince1970: 1_000), locationChanged: Date(timeIntervalSince1970: 9_000))

        let localFolderA = KdbxGroup(uuid: folderAUUID, name: "A", iconID: 0, creationTime: Date(timeIntervalSince1970: 500), lastModificationTime: Date(timeIntervalSince1970: 500), locationChanged: Date(timeIntervalSince1970: 500), entries: [], subgroups: [])
        let localFolderB = KdbxGroup(uuid: folderBUUID, name: "B", iconID: 0, creationTime: Date(timeIntervalSince1970: 500), lastModificationTime: Date(timeIntervalSince1970: 500), locationChanged: Date(timeIntervalSince1970: 500), entries: [entryInB], subgroups: [])
        let local = makeDatabase(rootUUID: rootUUID, subgroups: [localFolderA, localFolderB])

        let remoteFolderA = KdbxGroup(uuid: folderAUUID, name: "A", iconID: 0, creationTime: Date(timeIntervalSince1970: 500), lastModificationTime: Date(timeIntervalSince1970: 500), locationChanged: Date(timeIntervalSince1970: 500), entries: [entryInA], subgroups: [])
        let remoteFolderB = KdbxGroup(uuid: folderBUUID, name: "B", iconID: 0, creationTime: Date(timeIntervalSince1970: 500), lastModificationTime: Date(timeIntervalSince1970: 500), locationChanged: Date(timeIntervalSince1970: 500), entries: [], subgroups: [])
        let remote = makeDatabase(rootUUID: rootUUID, subgroups: [remoteFolderA, remoteFolderB])

        let merged = MergeEngine.merge(local: local, remote: remote)

        let mergedFolderB = merged.rootGroup.subgroups.first { $0.uuid == folderBUUID }!
        let mergedFolderA = merged.rootGroup.subgroups.first { $0.uuid == folderAUUID }!
        XCTAssertTrue(mergedFolderB.entries.contains { $0.uuid == entryUUID }, "local's newer locationChanged (folder B) must win")
        XCTAssertFalse(mergedFolderA.entries.contains { $0.uuid == entryUUID })
    }

    func testMoveRemoteNewerLocationWins() {
        let rootUUID = UUID()
        let folderAUUID = UUID()
        let folderBUUID = UUID()
        let entryUUID = UUID()

        let entryInA = makeEntry(uuid: entryUUID, title: "Moved", modified: Date(timeIntervalSince1970: 1_000), locationChanged: Date(timeIntervalSince1970: 9_000))
        let entryInB = makeEntry(uuid: entryUUID, title: "Moved", modified: Date(timeIntervalSince1970: 1_000), locationChanged: Date(timeIntervalSince1970: 1_000))

        let localFolderA = KdbxGroup(uuid: folderAUUID, name: "A", iconID: 0, creationTime: Date(timeIntervalSince1970: 500), lastModificationTime: Date(timeIntervalSince1970: 500), locationChanged: Date(timeIntervalSince1970: 500), entries: [entryInA], subgroups: [])
        let localFolderB = KdbxGroup(uuid: folderBUUID, name: "B", iconID: 0, creationTime: Date(timeIntervalSince1970: 500), lastModificationTime: Date(timeIntervalSince1970: 500), locationChanged: Date(timeIntervalSince1970: 500), entries: [], subgroups: [])
        let local = makeDatabase(rootUUID: rootUUID, subgroups: [localFolderA, localFolderB])

        let remoteFolderA = KdbxGroup(uuid: folderAUUID, name: "A", iconID: 0, creationTime: Date(timeIntervalSince1970: 500), lastModificationTime: Date(timeIntervalSince1970: 500), locationChanged: Date(timeIntervalSince1970: 500), entries: [], subgroups: [])
        let remoteFolderB = KdbxGroup(uuid: folderBUUID, name: "B", iconID: 0, creationTime: Date(timeIntervalSince1970: 500), lastModificationTime: Date(timeIntervalSince1970: 500), locationChanged: Date(timeIntervalSince1970: 500), entries: [entryInB], subgroups: [])
        let remote = makeDatabase(rootUUID: rootUUID, subgroups: [remoteFolderA, remoteFolderB])

        let merged = MergeEngine.merge(local: local, remote: remote)

        let mergedFolderA = merged.rootGroup.subgroups.first { $0.uuid == folderAUUID }!
        let mergedFolderB = merged.rootGroup.subgroups.first { $0.uuid == folderBUUID }!
        XCTAssertTrue(mergedFolderA.entries.contains { $0.uuid == entryUUID }, "remote's newer locationChanged (folder A) must win")
        XCTAssertFalse(mergedFolderB.entries.contains { $0.uuid == entryUUID })
    }

    // Rule 7: deletedObjects union.

    func testDeletedObjectsUnionKeepsLaterDeletionTime() {
        let rootUUID = UUID()
        let deletedUUID = UUID()
        let local = makeDatabase(
            rootUUID: rootUUID,
            deletedObjects: [KdbxDeletedObject(uuid: deletedUUID, deletionTime: Date(timeIntervalSince1970: 1_000))]
        )
        let remote = makeDatabase(
            rootUUID: rootUUID,
            deletedObjects: [KdbxDeletedObject(uuid: deletedUUID, deletionTime: Date(timeIntervalSince1970: 9_000))]
        )

        let merged = MergeEngine.merge(local: local, remote: remote)

        let mergedDeletion = merged.deletedObjects.first { $0.uuid == deletedUUID }
        XCTAssertEqual(mergedDeletion?.deletionTime, Date(timeIntervalSince1970: 9_000))
        XCTAssertEqual(merged.deletedObjects.filter { $0.uuid == deletedUUID }.count, 1, "no duplicate entries for the same uuid")
    }

    // Rule 8: recycleBinGroupUUID.

    func testRecycleBinGroupUUIDPrefersNonNil() {
        let rootUUID = UUID()
        let recycleBinUUID = UUID()

        let bothNonNilSame = MergeEngine.merge(
            local: makeDatabase(rootUUID: rootUUID, recycleBinGroupUUID: recycleBinUUID),
            remote: makeDatabase(rootUUID: rootUUID, recycleBinGroupUUID: recycleBinUUID)
        )
        XCTAssertEqual(bothNonNilSame.recycleBinGroupUUID, recycleBinUUID)

        let onlyLocalNonNil = MergeEngine.merge(
            local: makeDatabase(rootUUID: rootUUID, recycleBinGroupUUID: recycleBinUUID),
            remote: makeDatabase(rootUUID: rootUUID, recycleBinGroupUUID: nil)
        )
        XCTAssertEqual(onlyLocalNonNil.recycleBinGroupUUID, recycleBinUUID)

        let onlyRemoteNonNil = MergeEngine.merge(
            local: makeDatabase(rootUUID: rootUUID, recycleBinGroupUUID: nil),
            remote: makeDatabase(rootUUID: rootUUID, recycleBinGroupUUID: recycleBinUUID)
        )
        XCTAssertEqual(onlyRemoteNonNil.recycleBinGroupUUID, recycleBinUUID)

        let bothNil = MergeEngine.merge(
            local: makeDatabase(rootUUID: rootUUID, recycleBinGroupUUID: nil),
            remote: makeDatabase(rootUUID: rootUUID, recycleBinGroupUUID: nil)
        )
        XCTAssertNil(bothNil.recycleBinGroupUUID)
    }
}
