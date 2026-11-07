import XCTest
import MyPassKit
@testable import SyncKit

final class MergeEngineAttachmentTests: XCTestCase {
    // Duplicated privately from MergeEngineBasicTests, where the factories are not shared.
    private func makeDatabase(rootUUID: UUID, entries: [KdbxEntry] = []) -> KdbxDatabase {
        let t = Date(timeIntervalSince1970: 1_000)
        let root = KdbxGroup(
            uuid: rootUUID, name: "MyPass", iconID: 0,
            creationTime: t, lastModificationTime: t, locationChanged: t,
            entries: entries, subgroups: []
        )
        return KdbxDatabase(rootGroup: root, deletedObjects: [], recycleBinGroupUUID: nil)
    }

    private func makeEntry(
        uuid: UUID,
        title: String = "T",
        modified: TimeInterval,
        attachments: [KdbxAttachment] = [],
        history: [KdbxEntry] = []
    ) -> KdbxEntry {
        let date = Date(timeIntervalSince1970: modified)
        return KdbxEntry(
            uuid: uuid, iconID: 0,
            fields: [KdbxField(key: "Title", value: title, isProtected: false)],
            attachments: attachments,
            creationTime: date, lastModificationTime: date, lastAccessTime: date, locationChanged: date,
            history: history
        )
    }

    private func att(_ name: String, _ byte: UInt8) -> KdbxAttachment {
        KdbxAttachment(name: name, data: Data([byte]), isProtected: true)
    }

    func testNewerSideAttachmentsWinAndOlderGoesToHistoryWithItsAttachments() {
        let root = UUID(), id = UUID()
        let local = makeDatabase(rootUUID: root, entries: [makeEntry(uuid: id, title: "A", modified: 2_000, attachments: [att("old.txt", 1)])])
        let remote = makeDatabase(rootUUID: root, entries: [makeEntry(uuid: id, title: "B", modified: 3_000, attachments: [att("new.txt", 2)])])

        let entry = MergeEngine.merge(local: local, remote: remote).rootGroup.entries[0]

        XCTAssertEqual(entry.attachments, [att("new.txt", 2)])
        XCTAssertEqual(entry.history.count, 1)
        XCTAssertEqual(entry.history[0].attachments, [att("old.txt", 1)])
    }

    func testEntryOnlyOnOneSideKeepsItsAttachments() {
        let root = UUID()
        let a = makeEntry(uuid: UUID(), modified: 2_000, attachments: [att("a.bin", 7)])
        let remoteOnly = MergeEngine.merge(local: makeDatabase(rootUUID: root), remote: makeDatabase(rootUUID: root, entries: [a]))
        XCTAssertEqual(remoteOnly.rootGroup.entries.first?.attachments, [att("a.bin", 7)])
        let localOnly = MergeEngine.merge(local: makeDatabase(rootUUID: root, entries: [a]), remote: makeDatabase(rootUUID: root))
        XCTAssertEqual(localOnly.rootGroup.entries.first?.attachments, [att("a.bin", 7)])
    }

    func testEqualTimestampsKeepLocalAttachments() {
        let root = UUID(), id = UUID()
        let local = makeDatabase(rootUUID: root, entries: [makeEntry(uuid: id, modified: 2_000, attachments: [att("local", 1)])])
        let remote = makeDatabase(rootUUID: root, entries: [makeEntry(uuid: id, modified: 2_000, attachments: [att("remote", 2)])])
        let entry = MergeEngine.merge(local: local, remote: remote).rootGroup.entries[0]
        XCTAssertEqual(entry.attachments, [att("local", 1)])
    }

    func testAttachmentOnlyDifferenceIsNotDeduplicatedAwayFromHistory() {
        let root = UUID(), id = UUID()
        // Same fields; the older side differs from an existing history item only by attachments
        // (the history item shares uuid, mtime and fields with the loser).
        let historical = makeEntry(uuid: id, modified: 2_000, attachments: [])
        let local = makeDatabase(rootUUID: root, entries: [makeEntry(uuid: id, modified: 2_000, attachments: [att("x", 1)])])
        let remote = makeDatabase(rootUUID: root, entries: [makeEntry(uuid: id, modified: 3_000, attachments: [], history: [historical])])

        let entry = MergeEngine.merge(local: local, remote: remote).rootGroup.entries[0]

        XCTAssertEqual(entry.history.count, 2)
        XCTAssertTrue(entry.history.contains { $0.attachments == [att("x", 1)] })
    }

    func testLosingEntrysOwnHistoryIsUnionedIntoTheWinnersHistory() {
        let root = UUID(), id = UUID()
        let winnerSnap = makeEntry(uuid: id, title: "w1", modified: 1_500, attachments: [att("w.txt", 1)])
        let loserSnap = makeEntry(uuid: id, title: "l1", modified: 1_600, attachments: [att("l.txt", 2)])
        let local = makeDatabase(rootUUID: root, entries: [makeEntry(uuid: id, title: "L", modified: 2_000, history: [loserSnap])])
        let remote = makeDatabase(rootUUID: root, entries: [makeEntry(uuid: id, title: "R", modified: 3_000, history: [winnerSnap])])

        let entry = MergeEngine.merge(local: local, remote: remote).rootGroup.entries[0]

        XCTAssertEqual(entry.history.count, 3)
        XCTAssertEqual(entry.history.map(\.lastModificationTime.timeIntervalSince1970), [1_500, 1_600, 2_000])
        XCTAssertTrue(entry.history.contains { $0.attachments == [att("l.txt", 2)] })
    }

    func testSnapshotsPresentOnBothSidesAreNotDuplicated() {
        let root = UUID(), id = UUID()
        let shared = makeEntry(uuid: id, title: "s", modified: 1_500, attachments: [att("s.txt", 1)])
        let local = makeDatabase(rootUUID: root, entries: [makeEntry(uuid: id, title: "L", modified: 2_000, history: [shared])])
        let remote = makeDatabase(rootUUID: root, entries: [makeEntry(uuid: id, title: "R", modified: 3_000, history: [shared])])

        let entry = MergeEngine.merge(local: local, remote: remote).rootGroup.entries[0]

        XCTAssertEqual(entry.history.count, 2)
    }

    func testEqualTimestampsKeepDistinctRemoteVersionInHistory() {
        let root = UUID(), id = UUID()
        let local = makeDatabase(rootUUID: root, entries: [makeEntry(uuid: id, modified: 2_000, attachments: [att("local", 1)])])
        let remote = makeDatabase(rootUUID: root, entries: [makeEntry(uuid: id, modified: 2_000, attachments: [att("remote", 2)])])

        let entry = MergeEngine.merge(local: local, remote: remote).rootGroup.entries[0]

        XCTAssertEqual(entry.attachments, [att("local", 1)])
        XCTAssertEqual(entry.history.count, 1)
        XCTAssertEqual(entry.history[0].attachments, [att("remote", 2)])
    }

    func testEqualTimestampsWithIdenticalContentAddNoHistory() {
        let root = UUID(), id = UUID()
        let e = makeEntry(uuid: id, modified: 2_000, attachments: [att("same", 1)])
        let entry = MergeEngine.merge(local: makeDatabase(rootUUID: root, entries: [e]),
                                      remote: makeDatabase(rootUUID: root, entries: [e])).rootGroup.entries[0]
        XCTAssertTrue(entry.history.isEmpty)
    }

    func testMergedDatabaseSurvivesSaveAndOpen() throws {
        let root = UUID(), id = UUID()
        let local = makeDatabase(rootUUID: root, entries: [makeEntry(uuid: id, title: "A", modified: 2_000, attachments: [att("old.txt", 1)])])
        let remote = makeDatabase(rootUUID: root, entries: [makeEntry(uuid: id, title: "B", modified: 3_000, attachments: [att("new.txt", 2)])])
        let merged = MergeEngine.merge(local: local, remote: remote)

        let saved = try merged.save(password: "pw", cipher: .chaCha20, compression: .none)
        let reopened = try KdbxDatabase.open(data: saved, password: "pw")

        let entry = reopened.rootGroup.entries[0]
        XCTAssertEqual(entry.attachments, [att("new.txt", 2)])
        XCTAssertEqual(entry.history.first?.attachments, [att("old.txt", 1)])
    }
}
