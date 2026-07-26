import XCTest
import MyPassKit
@testable import MyPass

final class SecuritySettingsTouchIDTests: XCTestCase {
    var tempDir: URL!
    var fileStore: VaultFileStore!
    var biometricKeyStore: FakeBiometricKeyStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecuritySettingsTouchIDTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileStore = VaultFileStore(directory: tempDir)
        biometricKeyStore = FakeBiometricKeyStore()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testIsEnrolledReflectsFakeStoreState() throws {
        XCTAssertFalse(VaultBiometricEnrollment.isEnrolled(biometricKeyStore: biometricKeyStore))

        try biometricKeyStore.store(derivedKey: Data(repeating: 0xAB, count: 32), account: "master")
        XCTAssertTrue(VaultBiometricEnrollment.isEnrolled(biometricKeyStore: biometricKeyStore))
    }

    func testEnrollStoresDerivedKeyForMasterAccount() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")
        let vaultData = try XCTUnwrap(fileStore.load())

        try VaultBiometricEnrollment.enroll(
            password: "correct-horse",
            vaultData: vaultData,
            biometricKeyStore: biometricKeyStore
        )

        let stored = try XCTUnwrap(biometricKeyStore.retrieve(account: "master"))
        XCTAssertEqual(stored.count, 32)
        XCTAssertEqual(
            stored,
            try VaultBiometricEnrollment.deriveTransformedKey(password: "correct-horse", vaultData: vaultData)
        )
    }

    func testEnrollWithWrongPasswordDoesNotStoreKey() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")
        let vaultData = try XCTUnwrap(fileStore.load())

        XCTAssertThrowsError(
            try VaultBiometricEnrollment.enroll(
                password: "wrong-password",
                vaultData: vaultData,
                biometricKeyStore: biometricKeyStore
            )
        ) { error in
            XCTAssertEqual(error as? KdbxDatabaseError, .wrongPassword)
        }

        XCTAssertFalse(VaultBiometricEnrollment.isEnrolled(biometricKeyStore: biometricKeyStore))
    }

    func testRemoveClearsEnrollment() throws {
        try biometricKeyStore.store(derivedKey: Data(repeating: 0xCD, count: 32), account: "master")
        XCTAssertTrue(VaultBiometricEnrollment.isEnrolled(biometricKeyStore: biometricKeyStore))

        try VaultBiometricEnrollment.remove(biometricKeyStore: biometricKeyStore)

        XCTAssertFalse(VaultBiometricEnrollment.isEnrolled(biometricKeyStore: biometricKeyStore))
        XCTAssertNil(try biometricKeyStore.retrieve(account: "master"))
    }
}
