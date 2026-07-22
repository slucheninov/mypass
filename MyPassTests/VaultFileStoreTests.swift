import XCTest
@testable import MyPass

final class VaultFileStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPassVaultFileStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLoadReturnsNilWhenNoVaultExists() throws {
        let store = VaultFileStore(directory: tempDir)
        XCTAssertNil(try store.load())
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = VaultFileStore(directory: tempDir)
        let payload = Data("hello vault".utf8)
        try store.save(data: payload)
        XCTAssertEqual(try store.load(), payload)
    }

    func testBackupRotationKeepsOnlyBackupCountFiles() throws {
        let store = VaultFileStore(directory: tempDir, backupCount: 2)
        for i in 0..<5 {
            try store.save(data: Data("version \(i)".utf8))
        }
        let backupsDir = tempDir.appendingPathComponent("backups")
        let backups = try FileManager.default.contentsOfDirectory(atPath: backupsDir.path)
        XCTAssertEqual(backups.count, 2)
    }
}
