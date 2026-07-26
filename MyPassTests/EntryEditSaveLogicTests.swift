import XCTest
import MyPassKit
@testable import MyPass

final class EntryEditSaveLogicTests: XCTestCase {
    func testResolvedTitleUsesRegistrableDomainWhenTitleEmpty() {
        XCTAssertEqual(
            EntryEditSaveLogic.resolvedTitle(draftTitle: "", url: "https://login.example.com"),
            "example.com"
        )
    }

    func testResolvedTitlePreservesExplicitTitle() {
        XCTAssertEqual(
            EntryEditSaveLogic.resolvedTitle(draftTitle: "My Login", url: "https://example.com"),
            "My Login"
        )
    }

    func testResolvedTitleEmptyWhenBothEmpty() {
        XCTAssertEqual(EntryEditSaveLogic.resolvedTitle(draftTitle: "", url: ""), "")
    }

    func testApplyOTPEmptyInputOnEditLeavesExistingSecret() {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: []
        )
        entry.totpSecretBase32 = "EXISTING"
        EntryEditSaveLogic.applyOTP(to: &entry, otpauthInput: "")
        XCTAssertEqual(entry.totpSecretBase32, "EXISTING")
    }

    func testApplyOTPEmptyInputOnCreateLeavesNil() {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: []
        )
        EntryEditSaveLogic.applyOTP(to: &entry, otpauthInput: "")
        XCTAssertNil(entry.totpSecretBase32)
    }

    func testApplyOTPSavesRawBase32() {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: []
        )
        EntryEditSaveLogic.applyOTP(to: &entry, otpauthInput: "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(entry.totpSecretBase32, "JBSWY3DPEHPK3PXP")
    }
}
