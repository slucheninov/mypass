import XCTest
import MyPassKit
@testable import MyPass

final class EntryActionMenuModelTests: XCTestCase {
    private func makeEntry(_ type: EntryType = .login) -> KdbxEntry {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: now,
            lastModificationTime: now,
            lastAccessTime: now,
            locationChanged: now,
            history: []
        )
        entry.entryType = type
        return entry
    }

    private func sections(_ entry: KdbxEntry, bin: Bool = false) -> [[EntryActionMenuModel.Item]] {
        EntryActionMenuModel(entry: entry, isInRecycleBin: bin).sections
    }

    func testLoginWithTotpAndUrlListsEveryItemInOrder() {
        var entry = makeEntry()
        entry.login = "alice"
        entry.password = "pw"
        entry.url = "example.com"
        entry.totpSecretBase32 = "JBSWY3DPEHPK3PXP"
        XCTAssertEqual(sections(entry), [
            [.toggleFavorite(isFavorite: false), .moveToGroup],
            [.copy(.username, isEnabled: true), .copy(.password, isEnabled: true), .copy(.code, isEnabled: true), .openWebsite],
            [.viewHistory],
            [.delete]
        ])
    }

    func testLoginWithoutTotpOrUrlOmitsCodeAndOpenWebsite() {
        var entry = makeEntry()
        entry.login = "alice"
        entry.password = "pw"
        XCTAssertEqual(sections(entry)[1], [.copy(.username, isEnabled: true), .copy(.password, isEnabled: true)])
    }

    func testEmptyUsernameAndPasswordAreDisabledNotHidden() {
        let entry = makeEntry()
        XCTAssertEqual(sections(entry)[1], [.copy(.username, isEnabled: false), .copy(.password, isEnabled: false)])
    }

    func testFavoriteLabelStateFollowsTheEntry() {
        var entry = makeEntry()
        entry.isFavorite = true
        XCTAssertEqual(sections(entry)[0][0], .toggleFavorite(isFavorite: true))
    }

    func testCardOffersCardNumberAndCvvOnly() {
        var entry = makeEntry(.card)
        entry.cardNumber = "4111111111111111"
        entry.cvv = "123"
        XCTAssertEqual(sections(entry)[1], [.copy(.cardNumber, isEnabled: true), .copy(.cvv, isEnabled: true)])
    }

    func testNotesOffersCopyNoteOnly() {
        var entry = makeEntry(.notes)
        entry.notesBody = "hello"
        XCTAssertEqual(sections(entry)[1], [.copy(.note, isEnabled: true)])
    }

    func testAddressHasNoCopyGroupAndNoEmptySection() {
        let s = sections(makeEntry(.address))
        XCTAssertEqual(s.count, 3)
        XCTAssertTrue(s.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(s, [[.toggleFavorite(isFavorite: false), .moveToGroup], [.viewHistory], [.delete]])
    }

    func testRecycleBinEntryOffersRestoreAndDeletePermanentlyInsteadOfDelete() {
        let s = sections(makeEntry(), bin: true)
        XCTAssertEqual(s.last, [.restore, .deletePermanently])
        XCTAssertFalse(s.joined().contains(.delete))
    }

    func testNoSectionIsEverEmpty() {
        for type in [EntryType.login, .card, .notes, .address] {
            for bin in [false, true] {
                XCTAssertTrue(sections(makeEntry(type), bin: bin).allSatisfy { !$0.isEmpty }, "\(type) bin=\(bin)")
            }
        }
    }
}
