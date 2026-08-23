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

    /// Clearing the OTP field means "keep the existing secret" (per `applyOTP`'s
    /// empty-input semantics) — it must not trigger the replace-confirmation, even if
    /// the field was originally populated by a TOTP proposal from the extension.
    func testRequiresReplaceConfirmationFalseWhenInputClearedAfterProposalPrefill() {
        XCTAssertFalse(EntryEditSaveLogic.requiresReplaceConfirmation(existingSecret: "JBSWY3DP", currentOtpauthInput: ""))
    }

    func testRequiresReplaceConfirmationFalseWhenInputIdenticalToExisting() {
        XCTAssertFalse(EntryEditSaveLogic.requiresReplaceConfirmation(existingSecret: "JBSWY3DP", currentOtpauthInput: "JBSWY3DP"))
    }

    func testRequiresReplaceConfirmationTrueWhenInputDiffersFromExisting() {
        XCTAssertTrue(EntryEditSaveLogic.requiresReplaceConfirmation(existingSecret: "JBSWY3DP", currentOtpauthInput: "OTHERSECRET"))
    }

    func testRequiresReplaceConfirmationFalseWhenNoExistingSecret() {
        XCTAssertFalse(EntryEditSaveLogic.requiresReplaceConfirmation(existingSecret: nil, currentOtpauthInput: "ANYTHING"))
    }

    func testRequiresReplaceConfirmationFalseWhenExistingSecretIsEmptyString() {
        XCTAssertFalse(EntryEditSaveLogic.requiresReplaceConfirmation(existingSecret: "", currentOtpauthInput: "ANYTHING"))
    }

    /// A TOTP proposal from the extension pre-fills the OTP field (see
    /// `initialOtpauthInput`), and that prefill must still trigger the replace
    /// confirmation when it differs from an existing stored secret.
    func testRequiresReplaceConfirmationTrueWhenProposalPrefillDiffersFromExisting() {
        let prefilled = EntryEditSaveLogic.initialOtpauthInput(
            prefilled: "otpauth://totp/New:x?secret=NEWSECRET", existingSecret: "EXISTING"
        )
        XCTAssertTrue(EntryEditSaveLogic.requiresReplaceConfirmation(existingSecret: "EXISTING", currentOtpauthInput: prefilled))
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

    func testInitialOtpauthInputPrefersPrefilledProposalOverExistingSecret() {
        XCTAssertEqual(
            EntryEditSaveLogic.initialOtpauthInput(prefilled: "otpauth://totp/New:x?secret=NEWSECRET", existingSecret: "EXISTING"),
            "otpauth://totp/New:x?secret=NEWSECRET"
        )
    }

    func testInitialOtpauthInputFallsBackToExistingSecretWhenNoProposal() {
        XCTAssertEqual(
            EntryEditSaveLogic.initialOtpauthInput(prefilled: nil, existingSecret: "EXISTING"),
            "EXISTING"
        )
    }

    func testInitialOtpauthInputEmptyWhenNeitherPresent() {
        XCTAssertEqual(EntryEditSaveLogic.initialOtpauthInput(prefilled: nil, existingSecret: nil), "")
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

    // MARK: - Passkey removal

    private func makePasskeyEntry() -> KdbxEntry {
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: Date(), lastModificationTime: Date(), lastAccessTime: Date(), locationChanged: Date(),
            history: []
        )
        entry.title = "Example"
        entry.password = "hunter2"
        entry.passkeyRelyingParty = "example.com"
        entry.passkeyCredentialId = Data([1, 2, 3])
        entry.passkeyPrivateKeyPEM = "pem"
        entry.passkeyUsername = "alice"
        entry.passkeyCreatedAt = Date()
        return entry
    }

    func testApplyPasskeyRemovalClearsEveryPasskeyField() {
        var entry = makePasskeyEntry()
        EntryEditSaveLogic.applyPasskeyRemoval(to: &entry)

        XCTAssertFalse(entry.hasPasskey)
        XCTAssertNil(entry.passkeyRelyingParty)
        XCTAssertNil(entry.passkeyCreatedAt)
        XCTAssertTrue(entry.fields.filter { $0.key.hasPrefix("KPEX_PASSKEY_") }.isEmpty)
    }

    /// Every editor rebuilds `fields` as "standard keys, plus the custom rows on screen".
    /// Passkey fields appear in no custom row — deliberately, so the private key PEM is
    /// never an editable text box — so if they were not standard keys, the first ordinary
    /// edit of an entry would silently destroy a working passkey.
    func testPasskeyFieldsSurviveTheEditorsFieldRebuild() {
        let entry = makePasskeyEntry()
        var rebuilt = entry
        rebuilt.fields.removeAll { !KdbxEntry.standardFieldKeys.contains($0.key) }

        XCTAssertTrue(rebuilt.hasPasskey)
        XCTAssertEqual(rebuilt.passkeyRelyingParty, "example.com")
        XCTAssertEqual(rebuilt.passkeyPrivateKeyPEM, "pem")
        XCTAssertNotNil(rebuilt.passkeyCreatedAt)
    }

    /// The same property from the other side: passkey fields must not show up as generic
    /// custom-field rows in the detail card or the editor.
    func testPasskeyFieldsAreNotOfferedAsCustomFields() {
        var entry = makePasskeyEntry()
        entry.fields.append(KdbxField(key: "Recovery code", value: "abc", isProtected: false))

        XCTAssertEqual(entry.additionalFields.map(\.key), ["Recovery code"])
    }

    func testApplyPasskeyRemovalLeavesTheRestOfTheEntryIntact() {
        var entry = makePasskeyEntry()
        entry.totpSecretBase32 = "JBSWY3DPEHPK3PXP"
        EntryEditSaveLogic.applyPasskeyRemoval(to: &entry)

        XCTAssertEqual(entry.title, "Example")
        XCTAssertEqual(entry.password, "hunter2")
        XCTAssertEqual(entry.totpSecretBase32, "JBSWY3DPEHPK3PXP")
    }
}
