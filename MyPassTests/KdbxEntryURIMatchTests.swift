import XCTest
import MyPassKit
@testable import MyPass

final class KdbxEntryURIMatchTests: XCTestCase {
    private func makeEntry() -> KdbxEntry {
        let now = Date()
        return KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now,
            locationChanged: now, history: []
        )
    }

    func testAbsentFieldReadsAsRegistrableDomain() {
        let entry = makeEntry()
        XCTAssertEqual(entry.uriMatchMode, .registrableDomain)
    }

    func testUnrecognisedRawValueReadsAsRegistrableDomainRatherThanThrowing() {
        var entry = makeEntry()
        entry.fields.append(
            KdbxField(key: KdbxEntry.uriMatchModeFieldKey, value: "some-future-mode-this-version-does-not-know", isProtected: false)
        )
        XCTAssertEqual(entry.uriMatchMode, .registrableDomain)
    }

    func testSetThenReadRoundTrips() {
        var entry = makeEntry()
        entry.uriMatchMode = .exact
        XCTAssertEqual(entry.uriMatchMode, .exact)
        entry.uriMatchMode = .never
        XCTAssertEqual(entry.uriMatchMode, .never)
    }

    func testSettingBackToRegistrableDomainRemovesTheField() {
        var entry = makeEntry()
        entry.uriMatchMode = .host
        entry.uriMatchMode = .registrableDomain
        XCTAssertFalse(entry.fields.contains { $0.key == KdbxEntry.uriMatchModeFieldKey })
    }

    func testUriMatchModeFieldKeyIsAStandardFieldNotACustomField() {
        var entry = makeEntry()
        entry.uriMatchMode = .startsWith
        XCTAssertTrue(KdbxEntry.standardFieldKeys.contains(KdbxEntry.uriMatchModeFieldKey))
        XCTAssertTrue(entry.additionalFields.isEmpty, "MyPass.URIMatchMode must never render as a generic custom-field row")
    }

    func testUriMatchModeSurvivesAKdbxSaveAndReloadCycle() throws {
        var entry = makeEntry()
        entry.title = "Example"
        entry.url = "https://example.com"
        entry.uriMatchMode = .exact
        let group = KdbxGroup(
            uuid: UUID(), name: "MyPass", iconID: 0,
            creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(),
            entries: [entry], subgroups: []
        )
        let database = KdbxDatabase(rootGroup: group, deletedObjects: [])
        let data = try database.save(password: "correct-horse", cipher: .aes256, compression: .gzip)

        let reopened = try KdbxDatabase.open(data: data, password: "correct-horse")
        let reloadedEntry = try XCTUnwrap(reopened.rootGroup.entries.first { $0.uuid == entry.uuid })
        XCTAssertEqual(reloadedEntry.uriMatchMode, .exact)
    }

    func testEntryWithNoUriMatchModeFieldReloadsAsRegistrableDomain() throws {
        var entry = makeEntry()
        entry.title = "Example"
        entry.url = "https://example.com"
        // uriMatchMode deliberately left untouched — this is the "old file" shape every
        // pre-existing MyPass and KeePassXC vault already has.
        let group = KdbxGroup(
            uuid: UUID(), name: "MyPass", iconID: 0,
            creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(),
            entries: [entry], subgroups: []
        )
        let database = KdbxDatabase(rootGroup: group, deletedObjects: [])
        let data = try database.save(password: "correct-horse", cipher: .aes256, compression: .gzip)

        let reopened = try KdbxDatabase.open(data: data, password: "correct-horse")
        let reloadedEntry = try XCTUnwrap(reopened.rootGroup.entries.first { $0.uuid == entry.uuid })
        XCTAssertEqual(reloadedEntry.uriMatchMode, .registrableDomain)
    }
}
