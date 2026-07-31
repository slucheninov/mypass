import XCTest
import MyPassKit
import SyncKit
@testable import MyPass

final class OpenExistingVaultTests: XCTestCase {
    let password = "correct-horse"
    var appSupportDir: URL!
    var externalVaultURL: URL!
    var defaults: UserDefaults!
    var defaultsSuiteName: String!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenExistingVaultTests-\(UUID().uuidString)")
        appSupportDir = base.appendingPathComponent("AppSupport/MyPass")
        externalVaultURL = base.appendingPathComponent("external/legacy.kdbx")
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalVaultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defaultsSuiteName = "OpenExistingVaultTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: appSupportDir.deletingLastPathComponent().deletingLastPathComponent())
    }

    private func makeDatabase(title: String) throws -> KdbxDatabase {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now,
            lastAccessTime: now, locationChanged: now, history: []
        )
        entry.title = title
        let root = KdbxGroup(
            uuid: UUID(), name: "MyPass", iconID: 0,
            creationTime: now, lastModificationTime: now, locationChanged: now,
            entries: [entry], subgroups: []
        )
        return KdbxDatabase(rootGroup: root, deletedObjects: [])
    }

    func testRetargetFromDefaultLocalDeletesAppSupportVault() throws {
        let defaultStore = VaultFileStore(directory: appSupportDir)
        let session = VaultSession(fileStore: defaultStore)
        let oldDB = try makeDatabase(title: "Old")
        try defaultStore.save(data: try oldDB.save(password: password, cipher: .aes256, compression: .gzip))

        let newDB = try makeDatabase(title: "External")
        try Data().write(to: externalVaultURL) // placeholder replaced below
        let newData = try newDB.save(password: password, cipher: .aes256, compression: .gzip)
        try newData.write(to: externalVaultURL)
        let bookmark = try LocalFileVaultStore.createFileBookmark(for: externalVaultURL)

        try session.retargetToOpenExistingVault(
            fileURL: externalVaultURL,
            bookmarkData: bookmark,
            password: password,
            database: newDB,
            defaults: defaults
        )

        XCTAssertEqual(defaults.string(forKey: "vaultLocation"), VaultLocationOption.local.rawValue)
        XCTAssertEqual(defaults.data(forKey: SyncBackendResolver.localVaultFileBookmarkKey), bookmark)
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultStore.vaultURL.path))
        XCTAssertEqual(session.currentDatabase?.rootGroup.entries.first?.title, "External")
        XCTAssertTrue(session.currentPrimaryStore is LocalFileVaultStore)
    }

    func testRetargetFromICloudDoesNotDeleteICloudFile() throws {
        let icloudFolder = appSupportDir.deletingLastPathComponent().appendingPathComponent("icloud")
        try FileManager.default.createDirectory(at: icloudFolder, withIntermediateDirectories: true)
        let icloudBookmark = try iCloudBackend.createFolderBookmark(for: icloudFolder)
        let icloudStore = try ICloudDriveVaultStore(
            bookmarkData: icloudBookmark,
            localBackupDirectory: appSupportDir.appendingPathComponent("backups")
        )
        defaults.set(VaultLocationOption.iCloudDrive.rawValue, forKey: "vaultLocation")
        defaults.set(icloudBookmark, forKey: SyncBackendResolver.iCloudFolderBookmarkKey)

        let session = VaultSession(fileStore: icloudStore)
        let oldDB = try makeDatabase(title: "OldICloud")
        try icloudStore.save(data: try oldDB.save(password: password, cipher: .aes256, compression: .gzip))

        let newDB = try makeDatabase(title: "External")
        let newData = try newDB.save(password: password, cipher: .aes256, compression: .gzip)
        try newData.write(to: externalVaultURL)
        let fileBookmark = try LocalFileVaultStore.createFileBookmark(for: externalVaultURL)

        try session.retargetToOpenExistingVault(
            fileURL: externalVaultURL,
            bookmarkData: fileBookmark,
            password: password,
            database: newDB,
            defaults: defaults
        )

        XCTAssertNil(defaults.data(forKey: SyncBackendResolver.iCloudFolderBookmarkKey))
        XCTAssertNotNil(defaults.data(forKey: SyncBackendResolver.localVaultFileBookmarkKey))
        XCTAssertNotNil(try icloudStore.load())
    }
}
