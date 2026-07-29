import XCTest
import MyPassKit
@testable import MyPass

final class EntryCategoryFilterTests: XCTestCase {
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

    private func makeEntry(title: String, entryType: EntryType) -> KdbxEntry {
        var entry = makeEntry(title: title)
        entry.entryType = entryType
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

    func testAllFilterExcludesBin() {
        let live = makeEntry(title: "Live")
        let deleted = makeEntry(title: "Deleted")
        let db = makeDatabase(rootEntries: [live], binEntries: [deleted])
        let result = EntryCategoryFilter.entries(for: .all, in: db)
        XCTAssertEqual(result.map(\.title), ["Live"])
    }

    func testCodesFilterNonEmptyTOTP() {
        let withOTP = makeEntry(title: "OTP", totp: "SECRET")
        let db = makeDatabase(rootEntries: [withOTP, makeEntry(title: "Plain")])
        XCTAssertEqual(EntryCategoryFilter.entries(for: .codes, in: db).map(\.title), ["OTP"])
    }

    func testDeletedFilterBinOnly() {
        let deleted = makeEntry(title: "Bin")
        let db = makeDatabase(rootEntries: [makeEntry(title: "Live")], binEntries: [deleted])
        XCTAssertEqual(EntryCategoryFilter.entries(for: .deleted, in: db).map(\.title), ["Bin"])
    }

    func testFavoritesFilterIncludesOnlyFavoritedLiveEntries() {
        var favorite = makeEntry(title: "Favorite")
        favorite.isFavorite = true
        let plain = makeEntry(title: "Plain")
        var favoriteInBin = makeEntry(title: "FavoriteDeleted")
        favoriteInBin.isFavorite = true

        let db = makeDatabase(rootEntries: [favorite, plain], binEntries: [favoriteInBin])

        XCTAssertEqual(EntryCategoryFilter.entries(for: .favorites, in: db).map(\.title), ["Favorite"])
    }

    func testSearchIntersectionViaEntrySearch() {
        let db = makeDatabase(rootEntries: [
            makeEntry(title: "GitHub"),
            makeEntry(title: "GitLab")
        ])
        let filtered = EntryCategoryFilter.entries(for: .all, in: db)
            .filter { EntrySearch.matches(entry: $0, query: "hub") }
        XCTAssertEqual(filtered.map(\.title), ["GitHub"])
    }

    func testSearchMatchesNotesBodyContent() {
        var note = makeEntry(title: "Wifi Password", entryType: .notes)
        note.notesBody = "network passphrase is zebra-moonlight-42"
        let sibling = makeEntry(title: "Router Login", entryType: .notes)
        let db = makeDatabase(rootEntries: [note, sibling])

        let filtered = EntryCategoryFilter.entries(for: .all, in: db)
            .filter { EntrySearch.matches(entry: $0, query: "zebra-moonlight") }

        XCTAssertEqual(filtered.map(\.title), ["Wifi Password"])
    }

    func testCardsFilterIncludesOnlyCardEntries() {
        let card = makeEntry(title: "Visa", entryType: .card)
        let login = makeEntry(title: "GitHub")
        let db = makeDatabase(rootEntries: [card, login])
        XCTAssertEqual(EntryCategoryFilter.entries(for: .cards, in: db).map(\.title), ["Visa"])
    }

    func testNotesFilterIncludesOnlyNotesEntries() {
        let note = makeEntry(title: "Wifi Password", entryType: .notes)
        let login = makeEntry(title: "GitHub")
        let db = makeDatabase(rootEntries: [note, login])
        XCTAssertEqual(EntryCategoryFilter.entries(for: .notes, in: db).map(\.title), ["Wifi Password"])
    }

    func testCardsAndNotesFiltersExcludeBin() {
        let deletedCard = makeEntry(title: "DeletedCard", entryType: .card)
        let db = makeDatabase(rootEntries: [], binEntries: [deletedCard])
        XCTAssertEqual(EntryCategoryFilter.entries(for: .cards, in: db), [])
    }
}
