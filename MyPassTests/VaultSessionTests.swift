import XCTest
import MyPassKit
@testable import MyPass

final class VaultSessionTests: XCTestCase {
    var tempDir: URL!
    var fileStore: VaultFileStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPassVaultSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileStore = VaultFileStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testUnlockWithNoExistingVaultCreatesEmptyDatabase() throws {
        let session = VaultSession(fileStore: fileStore)
        XCTAssertEqual(session.state, .locked)
        try session.unlock(password: "correct-horse")
        guard case .unlocked(let db) = session.state else {
            return XCTFail("expected unlocked state")
        }
        XCTAssertEqual(db.rootGroup.name, "MyPass")
        XCTAssertEqual(db.rootGroup.entries.count, 0)
    }

    func testUnlockWithWrongPasswordThrowsAndStaysLocked() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")
        session.lock()

        let secondSession = VaultSession(fileStore: fileStore)
        XCTAssertThrowsError(try secondSession.unlock(password: "wrong-password")) { error in
            XCTAssertEqual(error as? KdbxDatabaseError, .wrongPassword)
        }
        XCTAssertEqual(secondSession.state, .locked)
    }
}
