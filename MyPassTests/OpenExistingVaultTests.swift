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

    /// The third `wasDefaultLocal` branch, previously unverified by any
    /// test: retargeting when the *previous* primary was already a
    /// bookmarked `LocalFileVaultStore` (the user had already done an
    /// "Open Existing…" once before, or was on some other non-default local
    /// file) — not the plain default `VaultFileStore`. This must NOT delete
    /// the first file: `oldStore is VaultFileStore` is false for a
    /// `LocalFileVaultStore`, so `wasDefaultLocal` should short-circuit to
    /// `false` and skip deletion entirely.
    func testRetargetFromBookmarkedLocalFileDoesNotDeleteIt() throws {
        let firstVaultURL = appSupportDir.deletingLastPathComponent().appendingPathComponent("first/first.kdbx")
        try FileManager.default.createDirectory(at: firstVaultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let firstDB = try makeDatabase(title: "First")
        try firstDB.save(password: password, cipher: .aes256, compression: .gzip).write(to: firstVaultURL)
        let firstBookmark = try LocalFileVaultStore.createFileBookmark(for: firstVaultURL)
        let firstStore = try LocalFileVaultStore(
            bookmarkData: firstBookmark,
            localBackupDirectory: appSupportDir.appendingPathComponent("backups")
        )

        defaults.set(VaultLocationOption.local.rawValue, forKey: "vaultLocation")
        defaults.set(firstBookmark, forKey: SyncBackendResolver.localVaultFileBookmarkKey)

        let session = VaultSession(fileStore: firstStore)
        let newDB = try makeDatabase(title: "External")
        let newData = try newDB.save(password: password, cipher: .aes256, compression: .gzip)
        try newData.write(to: externalVaultURL)
        let newBookmark = try LocalFileVaultStore.createFileBookmark(for: externalVaultURL)

        try session.retargetToOpenExistingVault(
            fileURL: externalVaultURL,
            bookmarkData: newBookmark,
            password: password,
            database: newDB,
            defaults: defaults
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: firstVaultURL.path))
        XCTAssertEqual(defaults.data(forKey: SyncBackendResolver.localVaultFileBookmarkKey), newBookmark)
        XCTAssertEqual(session.currentDatabase?.rootGroup.entries.first?.title, "External")
        XCTAssertTrue(session.currentPrimaryStore is LocalFileVaultStore)
    }

    /// A failed delete of the old default Application Support vault (e.g. a
    /// permissions error) must not roll back the retarget itself, and must
    /// not leave `state`/`sessionPassword` disagreeing with `fileStore`/
    /// `defaults` — the fix for the reviewer's "no rollback / inconsistent
    /// partial state" finding. Simulated here by removing the App Support
    /// directory's write permission after seeding it, so
    /// `VaultFileStore.deleteVaultFileIfPresent()` throws.
    func testRetargetStillCompletesWhenOldVaultDeleteFails() throws {
        let defaultStore = VaultFileStore(directory: appSupportDir)
        let session = VaultSession(fileStore: defaultStore)
        let oldDB = try makeDatabase(title: "Old")
        try defaultStore.save(data: try oldDB.save(password: password, cipher: .aes256, compression: .gzip))

        // Make the containing directory non-writable so the delete inside
        // `deleteVaultFileIfPresent()` throws, without needing to touch the
        // vault file itself (which must still be readable for the
        // `fileExists` check below to be meaningful).
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: appSupportDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appSupportDir.path) }

        let newDB = try makeDatabase(title: "External")
        let newData = try newDB.save(password: password, cipher: .aes256, compression: .gzip)
        try newData.write(to: externalVaultURL)
        let bookmark = try LocalFileVaultStore.createFileBookmark(for: externalVaultURL)

        let warning = try session.retargetToOpenExistingVault(
            fileURL: externalVaultURL,
            bookmarkData: bookmark,
            password: password,
            database: newDB,
            defaults: defaults
        )

        // The retarget itself must have fully committed despite the delete
        // failure: session state, defaults, and the primary store must all
        // agree on the new vault, not disagree with each other.
        XCTAssertNotNil(warning)
        XCTAssertEqual(defaults.string(forKey: "vaultLocation"), VaultLocationOption.local.rawValue)
        XCTAssertEqual(defaults.data(forKey: SyncBackendResolver.localVaultFileBookmarkKey), bookmark)
        XCTAssertEqual(session.currentDatabase?.rootGroup.entries.first?.title, "External")
        XCTAssertTrue(session.currentPrimaryStore is LocalFileVaultStore)
        XCTAssertNotNil(session.currentDatabase)
    }

    /// Finding 3: retargeting to a completely unrelated `.kdbx` (Open
    /// Existing) must clear any secondary `.folder`/`.sftp` `SyncEngine`
    /// checkpoint, the same way the regular Move flow already does — a
    /// checkpoint taken against the previous vault must never be trusted
    /// once the primary points at unrelated content, or the next secondary
    /// sync pass risks overwriting the remote with this vault's data, or
    /// merging the OLD vault's entries into it. `SyncBackendResolver.
    /// clearCheckpoint` always targets `UserDefaults.standard` (matching the
    /// Move flow's own unconditional use of it), independent of whichever
    /// `defaults` instance is passed to `retargetToOpenExistingVault` for
    /// the vault-location bookkeeping — so this test seeds/restores
    /// `.standard` directly rather than the test's own `defaults` suite.
    func testRetargetClearsSecondarySyncCheckpoints() throws {
        let folderKey = SyncBackendResolver.checkpointKey(for: .folder)
        let sftpKey = SyncBackendResolver.checkpointKey(for: .sftp)
        let priorFolderValue = UserDefaults.standard.object(forKey: folderKey)
        let priorSFTPValue = UserDefaults.standard.object(forKey: sftpKey)
        UserDefaults.standard.set(123.0, forKey: folderKey)
        UserDefaults.standard.set(456.0, forKey: sftpKey)
        addTeardownBlock {
            if let priorFolderValue {
                UserDefaults.standard.set(priorFolderValue, forKey: folderKey)
            } else {
                UserDefaults.standard.removeObject(forKey: folderKey)
            }
            if let priorSFTPValue {
                UserDefaults.standard.set(priorSFTPValue, forKey: sftpKey)
            } else {
                UserDefaults.standard.removeObject(forKey: sftpKey)
            }
        }

        let defaultStore = VaultFileStore(directory: appSupportDir)
        let session = VaultSession(fileStore: defaultStore)
        let oldDB = try makeDatabase(title: "Old")
        try defaultStore.save(data: try oldDB.save(password: password, cipher: .aes256, compression: .gzip))

        let newDB = try makeDatabase(title: "External")
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

        XCTAssertNil(
            UserDefaults.standard.object(forKey: folderKey),
            "a checkpoint taken against the previous vault must not survive a retarget to an unrelated vault"
        )
        XCTAssertNil(UserDefaults.standard.object(forKey: sftpKey))
    }
}
