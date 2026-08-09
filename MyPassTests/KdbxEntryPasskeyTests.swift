import XCTest
import MyPassKit
@testable import MyPass

final class KdbxEntryPasskeyTests: XCTestCase {
    private func makeEntry() -> KdbxEntry {
        let now = Date()
        return KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now,
            history: []
        )
    }

    func testPasskeyFieldsRoundTrip() {
        var entry = makeEntry()
        entry.passkeyRelyingParty = "example.com"
        entry.passkeyCredentialId = Data([1, 2, 3, 4])
        entry.passkeyPrivateKeyPEM = "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"
        entry.passkeyUserHandle = Data([9, 9, 9])
        entry.passkeyUsername = "alice"

        XCTAssertEqual(entry.passkeyRelyingParty, "example.com")
        XCTAssertEqual(entry.passkeyCredentialId, Data([1, 2, 3, 4]))
        XCTAssertEqual(entry.passkeyPrivateKeyPEM, "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----")
        XCTAssertEqual(entry.passkeyUserHandle, Data([9, 9, 9]))
        XCTAssertEqual(entry.passkeyUsername, "alice")
    }

    func testPasskeyFieldsAreNilWhenAbsent() {
        let entry = makeEntry()
        XCTAssertNil(entry.passkeyRelyingParty)
        XCTAssertNil(entry.passkeyCredentialId)
        XCTAssertNil(entry.passkeyPrivateKeyPEM)
        XCTAssertNil(entry.passkeyUserHandle)
        XCTAssertNil(entry.passkeyUsername)
    }

    func testPasskeyFieldsUseKeePassXCFieldNames() {
        var entry = makeEntry()
        entry.passkeyRelyingParty = "example.com"
        entry.passkeyCredentialId = Data([1])
        entry.passkeyPrivateKeyPEM = "pem"
        entry.passkeyUserHandle = Data([2])
        entry.passkeyUsername = "alice"

        let keys = Set(entry.fields.map(\.key))
        XCTAssertTrue(keys.contains("KPEX_PASSKEY_RELYING_PARTY"))
        XCTAssertTrue(keys.contains("KPEX_PASSKEY_CREDENTIAL_ID"))
        XCTAssertTrue(keys.contains("KPEX_PASSKEY_PRIVATE_KEY_PEM"))
        XCTAssertTrue(keys.contains("KPEX_PASSKEY_USER_HANDLE"))
        XCTAssertTrue(keys.contains("KPEX_PASSKEY_USERNAME"))
    }

    func testSecretPasskeyFieldsAreProtected() {
        var entry = makeEntry()
        entry.passkeyRelyingParty = "example.com"
        entry.passkeyCredentialId = Data([1])
        entry.passkeyPrivateKeyPEM = "pem"
        entry.passkeyUserHandle = Data([2])
        entry.passkeyUsername = "alice"

        func isProtected(_ key: String) -> Bool? {
            entry.fields.first(where: { $0.key == key })?.isProtected
        }
        XCTAssertEqual(isProtected("KPEX_PASSKEY_PRIVATE_KEY_PEM"), true)
        XCTAssertEqual(isProtected("KPEX_PASSKEY_CREDENTIAL_ID"), true)
        XCTAssertEqual(isProtected("KPEX_PASSKEY_USER_HANDLE"), true)
        XCTAssertEqual(isProtected("KPEX_PASSKEY_RELYING_PARTY"), false)
        XCTAssertEqual(isProtected("KPEX_PASSKEY_USERNAME"), false)
    }

    func testSettingFieldToNilRemovesItIndividually() {
        var entry = makeEntry()
        entry.passkeyRelyingParty = "example.com"
        entry.passkeyUsername = "alice"

        entry.passkeyUsername = nil

        XCTAssertNil(entry.passkeyUsername)
        XCTAssertEqual(entry.passkeyRelyingParty, "example.com")
    }

    func testSetPasskeyBackupFlagsWritesKeePassXCDefaults() {
        var entry = makeEntry()
        entry.setPasskeyBackupFlags()

        XCTAssertEqual(entry.fields.first(where: { $0.key == "KPEX_PASSKEY_FLAG_BE" })?.value, "1")
        XCTAssertEqual(entry.fields.first(where: { $0.key == "KPEX_PASSKEY_FLAG_BS" })?.value, "1")
    }

    func testClearPasskeyRemovesAllFields() {
        var entry = makeEntry()
        entry.passkeyRelyingParty = "example.com"
        entry.passkeyCredentialId = Data([1])
        entry.passkeyPrivateKeyPEM = "pem"
        entry.passkeyUserHandle = Data([2])
        entry.passkeyUsername = "alice"
        entry.setPasskeyBackupFlags()

        entry.clearPasskey()

        XCTAssertNil(entry.passkeyRelyingParty)
        XCTAssertNil(entry.passkeyCredentialId)
        XCTAssertNil(entry.passkeyPrivateKeyPEM)
        XCTAssertNil(entry.passkeyUserHandle)
        XCTAssertNil(entry.passkeyUsername)
        XCTAssertTrue(entry.fields.filter { $0.key.hasPrefix("KPEX_PASSKEY_") }.isEmpty)
    }

    func testClearPasskeyLeavesOtherFieldsUntouched() {
        var entry = makeEntry()
        entry.title = "Example"
        entry.password = "hunter2"
        entry.passkeyRelyingParty = "example.com"

        entry.clearPasskey()

        XCTAssertEqual(entry.title, "Example")
        XCTAssertEqual(entry.password, "hunter2")
    }

    // MARK: - Creation date

    func testPasskeyCreatedAtRoundTripsToTheSecond() {
        var entry = makeEntry()
        // ISO8601 without fractional seconds, so compare at whole-second resolution.
        let date = Date(timeIntervalSince1970: 1_754_700_000)
        entry.passkeyCreatedAt = date

        XCTAssertEqual(entry.passkeyCreatedAt?.timeIntervalSince1970, date.timeIntervalSince1970)
    }

    func testPasskeyCreatedAtIsNilWhenAbsent() {
        XCTAssertNil(makeEntry().passkeyCreatedAt)
    }

    /// A passkey imported from KeePassXC carries no creation date — that is expected,
    /// not corruption, and must read as `nil` rather than crash or invent a date.
    func testPasskeyCreatedAtIsNilWhenValueIsNotADate() {
        var entry = makeEntry()
        entry.setFieldValue("not a date", forKey: "KPEX_PASSKEY_CREATED", isProtected: false)
        XCTAssertNil(entry.passkeyCreatedAt)
    }

    func testPasskeyCreatedAtUsesItsOwnFieldAndIsClearedWithTheRest() {
        var entry = makeEntry()
        entry.passkeyCreatedAt = Date(timeIntervalSince1970: 1_754_700_000)
        XCTAssertTrue(entry.fields.contains { $0.key == "KPEX_PASSKEY_CREATED" })

        entry.clearPasskey()
        XCTAssertNil(entry.passkeyCreatedAt)
        XCTAssertTrue(entry.fields.filter { $0.key.hasPrefix("KPEX_PASSKEY_") }.isEmpty)
    }

    func testSettingPasskeyCreatedAtToNilRemovesTheField() {
        var entry = makeEntry()
        entry.passkeyCreatedAt = Date()
        entry.passkeyCreatedAt = nil
        XCTAssertFalse(entry.fields.contains { $0.key == "KPEX_PASSKEY_CREATED" })
    }

    func testBase64URLRoundTripsAndAcceptsUnpaddedInput() {
        let data = Data([0xFB, 0xEF, 0xBE, 0x00, 0x01])
        let encoded = PasskeyBase64URL.encode(data)
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertEqual(PasskeyBase64URL.decode(encoded), data)
        // A real Chrome payload sends unpadded base64url; decoding must re-pad.
        XCTAssertEqual(PasskeyBase64URL.decode("AQIDBA"), Data([1, 2, 3, 4]))
    }
}
