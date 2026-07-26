import XCTest
import MyPassKit
@testable import MyPass

final class RecentEntriesQueryTests: XCTestCase {
    func testReturnsTopFiveByLastAccessTimeDescending() {
        let db = makeDatabaseWithEntries(accessTimes: [100, 500, 300, 700, 200, 600, 400])
        let recent = RecentEntriesQuery.recent(in: db, limit: 5)
        XCTAssertEqual(recent.map { $0.lastAccessTime.timeIntervalSince1970 }, [700, 600, 500, 400, 300])
    }

    func testExcludesRecycleBinEntries() throws {
        var db = makeDatabaseWithEntries(accessTimes: [900, 800])
        let bin = GroupTreeOperations.recycleBinGroup(in: db.rootGroup, recycleBinGroupUUID: &db.recycleBinGroupUUID)
        var recycled = db.rootGroup.entries.removeLast()
        recycled.lastAccessTime = Date(timeIntervalSince1970: 9999)
        bin.entries.append(recycled)

        let recent = RecentEntriesQuery.recent(in: db, limit: 5)
        XCTAssertFalse(recent.contains(where: { $0.uuid == recycled.uuid }))
        XCTAssertEqual(recent.count, 1)
    }

    func testEmptyWhenNoQualifyingEntries() {
        let now = Date()
        let entry = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: [])
        let db = KdbxDatabase(rootGroup: KdbxGroup(uuid: UUID(), name: "Root", iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: [entry], subgroups: []), deletedObjects: [])
        var binUUID: UUID? = nil
        let bin = GroupTreeOperations.recycleBinGroup(in: db.rootGroup, recycleBinGroupUUID: &binUUID)
        var dbCopy = db
        dbCopy.recycleBinGroupUUID = binUUID
        bin.entries.append(entry)
        XCTAssertTrue(RecentEntriesQuery.recent(in: dbCopy).isEmpty)
    }

    private func makeDatabaseWithEntries(accessTimes: [TimeInterval]) -> KdbxDatabase {
        let now = Date()
        let entries = accessTimes.map { t in
            var e = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now, lastAccessTime: Date(timeIntervalSince1970: t), locationChanged: now, history: [])
            e.title = "Entry-\(Int(t))"
            return e
        }
        let root = KdbxGroup(uuid: UUID(), name: "Root", iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: entries, subgroups: [])
        return KdbxDatabase(rootGroup: root, deletedObjects: [])
    }
}
