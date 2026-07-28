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

    func testUrlsGetterMergesPrimaryAndExtrasDeduped() {
        var entry = makeEmptyEntry()
        entry.url = "https://primary.example.com"
        entry.stringArrays = [KdbxStringArray(key: KdbxEntry.additionalURLsStringArrayKey, values: ["https://extra.example.com", "https://primary.example.com"])]

        XCTAssertEqual(entry.urls, ["https://primary.example.com", "https://extra.example.com"])
    }

    func testUrlsGetterWithNoPrimaryUsesFirstExtraAsFirstResult() {
        var entry = makeEmptyEntry()
        entry.stringArrays = [KdbxStringArray(key: KdbxEntry.additionalURLsStringArrayKey, values: ["https://only-extra.example.com"])]

        XCTAssertEqual(entry.urls, ["https://only-extra.example.com"])
    }

    func testUrlsSetterSplitsPrimaryAndExtras() {
        var entry = makeEmptyEntry()
        entry.urls = ["https://primary.example.com", "https://extra1.example.com", "https://extra2.example.com"]

        XCTAssertEqual(entry.url, "https://primary.example.com")
        XCTAssertEqual(entry.stringArrays.first?.key, KdbxEntry.additionalURLsStringArrayKey)
        XCTAssertEqual(entry.stringArrays.first?.values, ["https://extra1.example.com", "https://extra2.example.com"])
    }

    func testUrlsSetterWithEmptyArrayClearsBothPrimaryAndStringArray() {
        var entry = makeEmptyEntry()
        entry.urls = ["https://primary.example.com", "https://extra.example.com"]

        entry.urls = []

        XCTAssertEqual(entry.url, "")
        XCTAssertTrue(entry.stringArrays.isEmpty)
    }

    func testAdditionalFieldsExcludesStandardKeys() {
        var entry = makeEmptyEntry()
        entry.fields.append(KdbxField(key: "Custom Field", value: "custom value", isProtected: false))

        let keys = Set(entry.additionalFields.map(\.key))
        XCTAssertEqual(keys, ["Custom Field"])
        XCTAssertFalse(keys.contains("Title"))
        XCTAssertFalse(keys.contains("URL"))
    }
}
