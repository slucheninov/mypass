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

    func testRequiresReplaceConfirmationWhenEntryHasExistingSecretAndFromProposal() {
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: Date(), lastModificationTime: Date(), lastAccessTime: Date(), locationChanged: Date(),
            history: []
        )
        entry.totpSecretBase32 = "JBSWY3DP"
        XCTAssertTrue(EntryEditSaveLogic.requiresReplaceConfirmation(existingEntry: entry, isFromTotpProposal: true))
    }

    func testRequiresReplaceConfirmationFalseWhenNotFromProposal() {
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: Date(), lastModificationTime: Date(), lastAccessTime: Date(), locationChanged: Date(),
            history: []
        )
        entry.totpSecretBase32 = "JBSWY3DP"
        XCTAssertFalse(EntryEditSaveLogic.requiresReplaceConfirmation(existingEntry: entry, isFromTotpProposal: false))
    }

    func testRequiresReplaceConfirmationFalseWhenNoExistingSecret() {
        let entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: Date(), lastModificationTime: Date(), lastAccessTime: Date(), locationChanged: Date(),
            history: []
        )
        XCTAssertFalse(EntryEditSaveLogic.requiresReplaceConfirmation(existingEntry: entry, isFromTotpProposal: true))
    }

    func testRequiresReplaceConfirmationFalseWhenCreatingNewEntry() {
        XCTAssertFalse(EntryEditSaveLogic.requiresReplaceConfirmation(existingEntry: nil, isFromTotpProposal: true))
    }

    func testApplyOTPRemovalClearsExistingSecret() {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: []
        )
        entry.totpSecretBase32 = "EXISTING"
        EntryEditSaveLogic.applyOTPRemoval(to: &entry)
        XCTAssertNil(entry.totpSecretBase32)
    }

    /// Removal-then-retype: if the user removes 2FA and then types a new
    /// secret before saving, the new value must win over the removal.
    func testApplyOTPRemovalThenApplyOTPWithNewInputWins() {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: []
        )
        entry.totpSecretBase32 = "EXISTING"
        EntryEditSaveLogic.applyOTPRemoval(to: &entry)
        EntryEditSaveLogic.applyOTP(to: &entry, otpauthInput: "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(entry.totpSecretBase32, "JBSWY3DPEHPK3PXP")
    }

    func testApplyOTPParsesOtpauthURL() {
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: Date(), lastModificationTime: Date(), lastAccessTime: Date(), locationChanged: Date(),
            history: []
        )
        EntryEditSaveLogic.applyOTP(to: &entry, otpauthInput: "otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP&issuer=Example")
        XCTAssertEqual(entry.totpSecretBase32, "JBSWY3DPEHPK3PXP")
    }
}
