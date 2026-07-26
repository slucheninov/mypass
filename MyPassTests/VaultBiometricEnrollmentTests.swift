import XCTest
import MyPassKit
@testable import MyPass

final class VaultBiometricEnrollmentTests: XCTestCase {
    var tempDir: URL!
    var fileStore: VaultFileStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultBiometricEnrollmentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileStore = VaultFileStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDeriveTransformedKeyMatchesUnlockPassword() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")

        let data = try XCTUnwrap(fileStore.load())
        let derived = try VaultBiometricEnrollment.deriveTransformedKey(password: "correct-horse", vaultData: data)
        XCTAssertEqual(derived.count, 32)

        _ = try KdbxDatabase.open(data: data, password: "correct-horse")
    }

    func testDeriveTransformedKeyRejectsWrongPassword() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")

        let data = try XCTUnwrap(fileStore.load())
        XCTAssertThrowsError(
            try VaultBiometricEnrollment.deriveTransformedKey(password: "wrong-password", vaultData: data)
        ) { error in
            XCTAssertEqual(error as? KdbxDatabaseError, .wrongPassword)
        }
    }
}
