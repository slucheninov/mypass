import XCTest
import MyPassKit
@testable import MyPass

final class DeviceUnlockEnrollmentTests: XCTestCase {
    var tempDir: URL!
    var fileStore: VaultFileStore!
    var biometricKeyStore: FakeBiometricKeyStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceUnlockEnrollmentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileStore = VaultFileStore(directory: tempDir)
        biometricKeyStore = FakeBiometricKeyStore()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testIsEnrolledReflectsFakeStoreState() throws {
        XCTAssertFalse(DeviceUnlockEnrollment.isEnrolled(biometricKeyStore: biometricKeyStore))

        try DeviceUnlockEnrollment.enroll(
            password: "correct-horse",
            accessControl: .touchID,
            biometricKeyStore: biometricKeyStore
        )

        XCTAssertTrue(DeviceUnlockEnrollment.isEnrolled(biometricKeyStore: biometricKeyStore))
    }

    func testEnrollStoresPlaintextPasswordRetrievableLater() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")

        try DeviceUnlockEnrollment.enroll(
            password: "correct-horse",
            accessControl: .touchIDOrDevicePassword,
            biometricKeyStore: biometricKeyStore
        )

        let retrieved = try DeviceUnlockEnrollment.retrievePassword(biometricKeyStore: biometricKeyStore)
        XCTAssertEqual(retrieved, "correct-horse")
    }

    func testEnrollUsesRequestedAccessControl() throws {
        try DeviceUnlockEnrollment.enroll(
            password: "correct-horse",
            accessControl: .devicePassword,
            biometricKeyStore: biometricKeyStore
        )

        XCTAssertEqual(biometricKeyStore.accessControls[DeviceUnlockEnrollment.account], .devicePassword)
    }

    func testRetrievePasswordThrowsWhenNotEnrolled() {
        XCTAssertThrowsError(try DeviceUnlockEnrollment.retrievePassword(biometricKeyStore: biometricKeyStore)) { error in
            XCTAssertEqual(error as? DeviceUnlockError, .notEnrolled)
        }
    }

    func testRemoveClearsEnrollment() throws {
        try DeviceUnlockEnrollment.enroll(
            password: "correct-horse",
            accessControl: .touchID,
            biometricKeyStore: biometricKeyStore
        )
        XCTAssertTrue(DeviceUnlockEnrollment.isEnrolled(biometricKeyStore: biometricKeyStore))

        try DeviceUnlockEnrollment.remove(biometricKeyStore: biometricKeyStore)

        XCTAssertFalse(DeviceUnlockEnrollment.isEnrolled(biometricKeyStore: biometricKeyStore))
        XCTAssertThrowsError(try DeviceUnlockEnrollment.retrievePassword(biometricKeyStore: biometricKeyStore)) { error in
            XCTAssertEqual(error as? DeviceUnlockError, .notEnrolled)
        }
    }
}
