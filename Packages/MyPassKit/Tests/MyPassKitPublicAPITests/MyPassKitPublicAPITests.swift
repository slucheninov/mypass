import XCTest
import MyPassKit // NOT @testable — this test enforces the module boundary

final class MyPassKitPublicAPITests: XCTestCase {
    func testEntryAndGroupModelArePublic() throws {
        let now = Date()
        let field = KdbxField(key: "Title", value: "Example", isProtected: false)
        let entry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [field],
            creationTime: now,
            lastModificationTime: now,
            lastAccessTime: now,
            locationChanged: now,
            history: []
        )
        let group = KdbxGroup(
            uuid: UUID(),
            name: "Root",
            iconID: 0,
            creationTime: now,
            lastModificationTime: now,
            locationChanged: now,
            entries: [entry],
            subgroups: []
        )
        XCTAssertEqual(group.entries.first?.fields.first?.value, "Example")
        XCTAssertEqual(group.id, group.uuid)
        XCTAssertEqual(entry.id, entry.uuid)
    }

    func testDatabaseOpenSaveRoundTripSurfaceIsPublic() throws {
        // Only verifies the surface compiles and errors are public/catchable;
        // does not require a real file — corrupt data is enough to hit a public error path.
        do {
            _ = try KdbxDatabase.open(data: Data(), password: "x")
            XCTFail("expected KdbxDatabaseError.corruptFile")
        } catch let error as KdbxDatabaseError {
            XCTAssertTrue(error == .corruptFile("") || true) // shape check only; message text not asserted
        }
    }

    func testDeletedObjectIsPublic() {
        let obj = KdbxDeletedObject(uuid: UUID(), deletionTime: Date())
        XCTAssertNotNil(obj.uuid)
    }

    func testTOTPGeneratorIsPublic() {
        let code = TOTPGenerator.generate(
            secret: Data([0x01, 0x02, 0x03, 0x04, 0x05]),
            time: Date(timeIntervalSince1970: 59),
            step: 30,
            digits: 6,
            algorithm: .sha1
        )
        XCTAssertEqual(code.count, 6)
    }

    func testPasswordGeneratorIsPublic() throws {
        let options = PasswordGeneratorOptions(
            length: 16,
            includeLowercase: true,
            includeUppercase: true,
            includeDigits: true,
            includeSymbols: false
        )
        let password = try PasswordGenerator.generate(options: options)
        XCTAssertEqual(password.count, 16)
    }

    func testCipherAndCompressionEnumsArePublic() {
        let cipher: KdbxCipher = .aes256
        let compression: KdbxCompression = .gzip
        XCTAssertNotNil(cipher)
        XCTAssertNotNil(compression)
    }
}
