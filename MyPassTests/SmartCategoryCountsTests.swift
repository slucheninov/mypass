import XCTest
import MyPassKit
@testable import MyPass

final class SmartCategoryCountsTests: XCTestCase {
    private func makeEntry(title: String, totp: String? = nil) -> KdbxEntry {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: []
        )
        entry.title = title
        entry.totpSecretBase32 = totp
        return entry
    }

    private func makeDatabase(rootEntries: [KdbxEntry] = [], binEntries: [KdbxEntry] = []) -> KdbxDatabase {
        let now = Date()
        let root = KdbxGroup(
            uuid: UUID(), name: "Root", iconID: 0,
            creationTime: now, lastModificationTime: now, locationChanged: now,
            entries: rootEntries, subgroups: []
        )
        var db = KdbxDatabase(rootGroup: root, deletedObjects: [])
        let bin = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &db.recycleBinGroupUUID)
        bin.entries.append(contentsOf: binEntries)
        return db
    }

    func testAllCountExcludesRecycleBin() {
        let db = makeDatabase(
            rootEntries: [makeEntry(title: "A"), makeEntry(title: "B")],
            binEntries: [makeEntry(title: "Deleted")]
        )
        XCTAssertEqual(SmartCategoryCounts.countDisplay(for: .all, database: db), "2")
    }

    func testCodesCountNonEmptyTOTP() {
        let db = makeDatabase(rootEntries: [
            makeEntry(title: "WithOTP", totp: "JBSWY3DPEHPK3PXP"),
            makeEntry(title: "NoOTP")
        ])
        XCTAssertEqual(SmartCategoryCounts.countDisplay(for: .codes, database: db), "1")
    }

    func testDeletedCountBinOnly() {
        let db = makeDatabase(
            rootEntries: [makeEntry(title: "Live")],
            binEntries: [makeEntry(title: "D1"), makeEntry(title: "D2")]
        )
        XCTAssertEqual(SmartCategoryCounts.countDisplay(for: .deleted, database: db), "2")
    }

    func testFavoritesCountExcludesRecycleBin() {
        var favorite1 = makeEntry(title: "F1")
        favorite1.isFavorite = true
        var favorite2 = makeEntry(title: "F2")
        favorite2.isFavorite = true
        var favoriteInBin = makeEntry(title: "FavDeleted")
        favoriteInBin.isFavorite = true

        let db = makeDatabase(
            rootEntries: [favorite1, favorite2, makeEntry(title: "Plain")],
            binEntries: [favoriteInBin]
        )
        XCTAssertEqual(SmartCategoryCounts.countDisplay(for: .favorites, database: db), "2")
    }

    func testSecurityAlwaysEmDash() {
        let db = makeDatabase(rootEntries: [makeEntry(title: "A")])
        XCTAssertEqual(SmartCategoryCounts.countDisplay(for: .security, database: db), "—")
    }
}
