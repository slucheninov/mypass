import XCTest
import MyPassKit
@testable import MyPass

final class FilesEntryTypeTests: XCTestCase {
    private func makeEntry(title: String, type: EntryType = .login, files: [String] = []) -> KdbxEntry {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: []
        )
        entry.title = title
        entry.entryType = type
        entry.attachments = files.map { KdbxAttachment(name: $0, data: Data($0.utf8)) }
        return entry
    }

    private func makeDatabase(_ entries: [KdbxEntry], bin: [KdbxEntry] = []) -> KdbxDatabase {
        let now = Date()
        let root = KdbxGroup(
            uuid: UUID(), name: "Root", iconID: 0,
            creationTime: now, lastModificationTime: now, locationChanged: now,
            entries: entries, subgroups: []
        )
        var db = KdbxDatabase(rootGroup: root, deletedObjects: [])
        let binGroup = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &db.recycleBinGroupUUID)
        binGroup.entries.append(contentsOf: bin)
        return db
    }

    func testEntryTypeRoundTripsThroughCustomField() {
        var entry = makeEntry(title: "Docs")
        entry.entryType = .files
        XCTAssertEqual(entry.entryType, .files)
        XCTAssertEqual(entry.fields.first(where: { $0.key == "MyPass.EntryType" })?.value, "Files")
    }

    func testFilesFilterAndCountIncludeOnlyFilesEntries() {
        let files = makeEntry(title: "Passport scans", type: .files, files: ["p.pdf"])
        let loginWithAttachment = makeEntry(title: "GitHub", files: ["key.txt"])
        let deleted = makeEntry(title: "Old", type: .files)
        let db = makeDatabase([files, loginWithAttachment], bin: [deleted])
        XCTAssertEqual(EntryCategoryFilter.entries(for: .files, in: db).map(\.title), ["Passport scans"])
        XCTAssertEqual(SmartCategoryCounts.countDisplay(for: .files, database: db), "1")
    }

    func testSearchMatchesAttachmentNamesForAnyKind() {
        let login = makeEntry(title: "GitHub", files: ["recovery-codes.txt"])
        let files = makeEntry(title: "Scans", type: .files, files: ["passport.pdf"])
        XCTAssertTrue(EntrySearch.matches(entry: login, query: "RECOVERY"))
        XCTAssertTrue(EntrySearch.matches(entry: files, query: "passport"))
        XCTAssertFalse(EntrySearch.matches(entry: files, query: "recovery"))
    }

    func testListSubtitleShowsFileCountForFilesAndLoginOtherwise() {
        let files = makeEntry(title: "Scans", type: .files, files: ["a", "b", "c"])
        XCTAssertEqual(EntryListSubtitle.text(for: files), "3 files")
        XCTAssertEqual(EntryListSubtitle.fileCountText(1), "1 file")
        var login = makeEntry(title: "GitHub", files: ["a"])
        login.login = "ada"
        XCTAssertEqual(EntryListSubtitle.text(for: login), "ada")
    }

    func testActionMenuOffersNoCopyActionsForFiles() {
        let model = EntryActionMenuModel(entry: makeEntry(title: "Scans", type: .files), isInRecycleBin: false)
        XCTAssertFalse(model.sections.joined().contains { if case .copy = $0 { return true } else { return false } })
    }
}
