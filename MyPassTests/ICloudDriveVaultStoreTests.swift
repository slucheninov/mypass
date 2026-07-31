import XCTest
import SyncKit
@testable import MyPass

final class ICloudDriveVaultStoreTests: XCTestCase {
    var folderDir: URL!
    var backupDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ICloudDriveVaultStoreTests-\(UUID().uuidString)")
        folderDir = base.appendingPathComponent("folder")
        backupDir = base.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folderDir.deletingLastPathComponent())
    }

    func testLoadReturnsNilBeforeAnyWrite() throws {
        let bookmark = try iCloudBackend.createFolderBookmark(for: folderDir)
        let store = try ICloudDriveVaultStore(bookmarkData: bookmark, localBackupDirectory: backupDir)
        XCTAssertNil(try store.load())
    }

    func testSaveThenLoadRoundTrips() throws {
        let bookmark = try iCloudBackend.createFolderBookmark(for: folderDir)
        let store = try ICloudDriveVaultStore(bookmarkData: bookmark, localBackupDirectory: backupDir)
        try store.save(data: Data("icloud-primary-round-trip".utf8))
        XCTAssertEqual(try store.load(), Data("icloud-primary-round-trip".utf8))
    }

    func testSecondSaveRotatesPreviousContentIntoLocalBackupDirectory() throws {
        let bookmark = try iCloudBackend.createFolderBookmark(for: folderDir)
        let store = try ICloudDriveVaultStore(bookmarkData: bookmark, localBackupDirectory: backupDir)
        try store.save(data: Data("first-version".utf8))
        try store.save(data: Data("second-version".utf8))

        let backedUpFiles = try FileManager.default.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(backedUpFiles.count, 1)
        let backedUpData = try Data(contentsOf: backedUpFiles[0])
        XCTAssertEqual(backedUpData, Data("first-version".utf8))
        XCTAssertEqual(try store.load(), Data("second-version".utf8))
    }

    func testSaveSucceedsEvenWhenBackupStepFails() throws {
        let bookmark = try iCloudBackend.createFolderBookmark(for: folderDir)
        let store = try ICloudDriveVaultStore(bookmarkData: bookmark, localBackupDirectory: backupDir)
        try store.save(data: Data("first-version".utf8))

        // Sabotage the backup directory so the pre-save backup step (which now
        // has existing content to snapshot) fails the way an evicted iCloud
        // placeholder / `downloadTimedOut` read would in production — a plain
        // file sits where `backupCurrentContentIfPresent` expects a directory.
        try FileManager.default.removeItem(at: backupDir)
        try Data().write(to: backupDir)

        XCTAssertNoThrow(try store.save(data: Data("second-version".utf8)))
        XCTAssertEqual(try store.load(), Data("second-version".utf8))
    }

    func testRotatesOldestBackupsBeyondBackupCount() throws {
        let bookmark = try iCloudBackend.createFolderBookmark(for: folderDir)
        let store = try ICloudDriveVaultStore(bookmarkData: bookmark, localBackupDirectory: backupDir, backupCount: 2)
        try store.save(data: Data("v1".utf8))
        try store.save(data: Data("v2".utf8))
        try store.save(data: Data("v3".utf8))
        try store.save(data: Data("v4".utf8))

        let backedUpFiles = try FileManager.default.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(backedUpFiles.count, 2)
    }
}
