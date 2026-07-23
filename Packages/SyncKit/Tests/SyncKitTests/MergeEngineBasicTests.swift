import XCTest
import MyPassKit
@testable import SyncKit

private extension KdbxEntry {
    var title: String {
        fields.first(where: { $0.key == "Title" })?.value ?? ""
    }
}

final class MergeEngineBasicTests: XCTestCase {
    /// Builds a minimal single-entry database. `rootUUID` must match between
    /// `local` and `remote` databases in every test, since MergeEngine's root
    /// merge logic requires matching root UUIDs (see MergeEngine.swift rule 9).
    func makeDatabase(
        rootUUID: UUID,
        rootName: String = "MyPass",
        rootModified: Date = Date(timeIntervalSince1970: 1_000),
        entries: [KdbxEntry] = [],
        subgroups: [KdbxGroup] = [],
        deletedObjects: [KdbxDeletedObject] = [],
        recycleBinGroupUUID: UUID? = nil
    ) -> KdbxDatabase {
        let root = KdbxGroup(
            uuid: rootUUID,
            name: rootName,
            iconID: 0,
            creationTime: rootModified,
            lastModificationTime: rootModified,
            locationChanged: rootModified,
            entries: entries,
            subgroups: subgroups
        )
        return KdbxDatabase(rootGroup: root, deletedObjects: deletedObjects, recycleBinGroupUUID: recycleBinGroupUUID)
    }

    func makeEntry(
        uuid: UUID,
        title: String,
        modified: Date,
        history: [KdbxEntry] = []
    ) -> KdbxEntry {
        var entry = KdbxEntry(
            uuid: uuid,
            iconID: 0,
            fields: [],
            creationTime: modified,
            lastModificationTime: modified,
            lastAccessTime: modified,
            locationChanged: modified,
            history: history
        )
        entry.fields = [KdbxField(key: "Title", value: title, isProtected: false)]
        return entry
    }

    func testAddedOnlyLocally() {
        let rootUUID = UUID()
        let localOnlyEntry = makeEntry(uuid: UUID(), title: "LocalOnly", modified: Date(timeIntervalSince1970: 2_000))
        let local = makeDatabase(rootUUID: rootUUID, entries: [localOnlyEntry])
        let remote = makeDatabase(rootUUID: rootUUID, entries: [])

        let merged = MergeEngine.merge(local: local, remote: remote)

        XCTAssertEqual(merged.rootGroup.entries.count, 1)
        XCTAssertEqual(merged.rootGroup.entries.first?.uuid, localOnlyEntry.uuid)
    }

    func testAddedOnlyRemotely() {
        let rootUUID = UUID()
        let remoteOnlyEntry = makeEntry(uuid: UUID(), title: "RemoteOnly", modified: Date(timeIntervalSince1970: 2_000))
        let local = makeDatabase(rootUUID: rootUUID, entries: [])
        let remote = makeDatabase(rootUUID: rootUUID, entries: [remoteOnlyEntry])

        let merged = MergeEngine.merge(local: local, remote: remote)

        XCTAssertEqual(merged.rootGroup.entries.count, 1)
        XCTAssertEqual(merged.rootGroup.entries.first?.uuid, remoteOnlyEntry.uuid)
    }

    func testEditedBothNewerLocalWins() {
        let rootUUID = UUID()
        let entryUUID = UUID()
        let localEntry = makeEntry(uuid: entryUUID, title: "LocalNewer", modified: Date(timeIntervalSince1970: 3_000))
        let remoteEntry = makeEntry(uuid: entryUUID, title: "RemoteOlder", modified: Date(timeIntervalSince1970: 1_000))
        let local = makeDatabase(rootUUID: rootUUID, entries: [localEntry])
        let remote = makeDatabase(rootUUID: rootUUID, entries: [remoteEntry])

        let merged = MergeEngine.merge(local: local, remote: remote)

        XCTAssertEqual(merged.rootGroup.entries.count, 1)
        let winner = merged.rootGroup.entries.first!
        XCTAssertEqual(winner.title, "LocalNewer")
        XCTAssertTrue(winner.history.contains { $0.title == "RemoteOlder" })
    }

    func testEditedBothNewerRemoteWins() {
        let rootUUID = UUID()
        let entryUUID = UUID()
        let localEntry = makeEntry(uuid: entryUUID, title: "LocalOlder", modified: Date(timeIntervalSince1970: 1_000))
        let remoteEntry = makeEntry(uuid: entryUUID, title: "RemoteNewer", modified: Date(timeIntervalSince1970: 3_000))
        let local = makeDatabase(rootUUID: rootUUID, entries: [localEntry])
        let remote = makeDatabase(rootUUID: rootUUID, entries: [remoteEntry])

        let merged = MergeEngine.merge(local: local, remote: remote)

        XCTAssertEqual(merged.rootGroup.entries.count, 1)
        let winner = merged.rootGroup.entries.first!
        XCTAssertEqual(winner.title, "RemoteNewer")
        XCTAssertTrue(winner.history.contains { $0.title == "LocalOlder" })
    }

    func testEditedEqualTimestampsPrefersLocal() {
        let rootUUID = UUID()
        let entryUUID = UUID()
        let sameTime = Date(timeIntervalSince1970: 5_000)
        let localEntry = makeEntry(uuid: entryUUID, title: "LocalTie", modified: sameTime)
        let remoteEntry = makeEntry(uuid: entryUUID, title: "RemoteTie", modified: sameTime)
        let local = makeDatabase(rootUUID: rootUUID, entries: [localEntry])
        let remote = makeDatabase(rootUUID: rootUUID, entries: [remoteEntry])

        let merged = MergeEngine.merge(local: local, remote: remote)

        let winner = merged.rootGroup.entries.first!
        XCTAssertEqual(winner.title, "LocalTie")
        XCTAssertFalse(winner.history.contains { $0.title == "RemoteTie" }, "equal timestamps must not append history")
    }

    func testGroupMetadataMergeIndependentOfChildMerge() {
        let rootUUID = UUID()
        let childGroupUUID = UUID()
        let newEntryUUID = UUID()

        // Local: renames the child group, does not add the new entry.
        let localChildGroup = KdbxGroup(
            uuid: childGroupUUID,
            name: "RenamedByLocal",
            iconID: 1,
            creationTime: Date(timeIntervalSince1970: 1_000),
            lastModificationTime: Date(timeIntervalSince1970: 4_000),
            locationChanged: Date(timeIntervalSince1970: 1_000),
            entries: [],
            subgroups: []
        )
        // Remote: keeps the old name, but adds a new entry into the same group.
        let newEntry = makeEntry(uuid: newEntryUUID, title: "AddedByRemote", modified: Date(timeIntervalSince1970: 2_000))
        let remoteChildGroup = KdbxGroup(
            uuid: childGroupUUID,
            name: "OriginalName",
            iconID: 1,
            creationTime: Date(timeIntervalSince1970: 1_000),
            lastModificationTime: Date(timeIntervalSince1970: 1_500),
            locationChanged: Date(timeIntervalSince1970: 1_000),
            entries: [newEntry],
            subgroups: []
        )

        let local = makeDatabase(rootUUID: rootUUID, subgroups: [localChildGroup])
        let remote = makeDatabase(rootUUID: rootUUID, subgroups: [remoteChildGroup])

        let merged = MergeEngine.merge(local: local, remote: remote)

        XCTAssertEqual(merged.rootGroup.subgroups.count, 1)
        let mergedChild = merged.rootGroup.subgroups.first!
        XCTAssertEqual(mergedChild.name, "RenamedByLocal", "newer lastModificationTime wins group metadata")
        XCTAssertEqual(mergedChild.entries.count, 1)
        XCTAssertEqual(mergedChild.entries.first?.uuid, newEntryUUID, "child entry merge is independent of parent metadata winner")
    }
}
