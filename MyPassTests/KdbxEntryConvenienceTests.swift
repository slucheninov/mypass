import XCTest
import MyPassKit
@testable import MyPass

final class KdbxEntryConvenienceTests: XCTestCase {
    func makeEmptyEntry() -> KdbxEntry {
        let now = Date()
        return KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: now,
            lastModificationTime: now,
            lastAccessTime: now,
            locationChanged: now,
            history: []
        )
    }

    func testTitleGetterDefaultsToEmptyString() {
        let entry = makeEmptyEntry()
        XCTAssertEqual(entry.title, "")
    }

    func testTitleSetterCreatesFieldWhenMissing() {
        var entry = makeEmptyEntry()
        entry.title = "GitHub"
        XCTAssertEqual(entry.title, "GitHub")
        XCTAssertEqual(entry.fields.first(where: { $0.key == "Title" })?.value, "GitHub")
    }

    func testLoginRoundTrips() {
        var entry = makeEmptyEntry()
        entry.login = "alice"
        XCTAssertEqual(entry.login, "alice")
    }

    func testPasswordRoundTripsAndIsProtected() {
        var entry = makeEmptyEntry()
        entry.password = "s3cret"
        XCTAssertEqual(entry.password, "s3cret")
        XCTAssertEqual(entry.fields.first(where: { $0.key == "Password" })?.isProtected, true)
    }

    func testURLRoundTrips() {
        var entry = makeEmptyEntry()
        entry.url = "https://example.com"
        XCTAssertEqual(entry.url, "https://example.com")
    }

    func testNotesRoundTrips() {
        var entry = makeEmptyEntry()
        entry.notes = "some note"
        XCTAssertEqual(entry.notes, "some note")
    }

    func testTOTPSecretIsNilWhenAbsentAndRoundTripsWhenSet() {
        var entry = makeEmptyEntry()
        XCTAssertNil(entry.totpSecretBase32)
        entry.totpSecretBase32 = "JBSWY3DPEHPK3PXP"
        XCTAssertEqual(entry.totpSecretBase32, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(entry.fields.first(where: { $0.key == "otp" })?.isProtected, true)
        entry.totpSecretBase32 = nil
        XCTAssertNil(entry.totpSecretBase32)
    }
}
