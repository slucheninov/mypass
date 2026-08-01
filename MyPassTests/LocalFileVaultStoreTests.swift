import XCTest
@testable import MyPass

final class LocalFileVaultStoreTests: XCTestCase {
    var tempDir: URL!
    var vaultFileURL: URL!
    var backupDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFileVaultStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        vaultFileURL = tempDir.appendingPathComponent("my-vault.kdbx")
        backupDir = tempDir.appendingPathComponent("backups")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore(bookmark: Data) throws -> LocalFileVaultStore {
        try LocalFileVaultStore(bookmarkData: bookmark, localBackupDirectory: backupDir)
    }

    func testLoadReturnsNilBeforeAnyWrite() throws {
        try Data("seed".utf8).write(to: vaultFileURL)
        let bookmark = try LocalFileVaultStore.createFileBookmark(for: vaultFileURL)
        let store = try makeStore(bookmark: bookmark)
        try FileManager.default.removeItem(at: vaultFileURL)
        XCTAssertNil(try store.load())
    }

    func testSaveThenLoadRoundTripsThroughBookmark() throws {
        try Data("seed".utf8).write(to: vaultFileURL)
        let bookmark = try LocalFileVaultStore.createFileBookmark(for: vaultFileURL)
        let store = try makeStore(bookmark: bookmark)
        try store.save(data: Data("local-file-round-trip".utf8))
        XCTAssertEqual(try store.load(), Data("local-file-round-trip".utf8))
        XCTAssertEqual(store.primaryVaultFileURL?.path, vaultFileURL.path)
    }

    func testDeleteVaultFileIfPresentRemovesFile() throws {
        try Data("seed".utf8).write(to: vaultFileURL)
        let bookmark = try LocalFileVaultStore.createFileBookmark(for: vaultFileURL)
        let store = try makeStore(bookmark: bookmark)
        try store.save(data: Data("to-delete".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vaultFileURL.path))
        try store.deleteVaultFileIfPresent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultFileURL.path))
    }

    /// Finding 4 (sandbox-safe save): `save` must write directly to the
    /// bookmarked file, not to a sibling temp path in the same directory —
    /// there is no automated way to verify real sandbox extension behavior
    /// in this environment, but this at least pins down that no stray
    /// `.tmp-*` sibling is left behind (the old `replaceItemAt` dance would
    /// leave one on any failure between the two steps, and always touched a
    /// second path even on success).
    func testSaveLeavesNoTempSiblingFile() throws {
        try Data("seed".utf8).write(to: vaultFileURL)
        let bookmark = try LocalFileVaultStore.createFileBookmark(for: vaultFileURL)
        let store = try makeStore(bookmark: bookmark)
        try store.save(data: Data("direct-write".utf8))

        let siblingEntries = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertFalse(
            siblingEntries.contains { $0.hasPrefix(".tmp-") },
            "save() must not create a temp sibling file outside the bookmark's granted scope"
        )
    }

    /// Finding 5: `LocalFileVaultStore` had no backup rotation at all —
    /// every autosave overwrote in place with zero recoverable prior
    /// versions. Mirrors `VaultFileStore`/`ICloudDriveVaultStore`'s
    /// "snapshot before overwrite" contract.
    func testSaveSnapshotsPreviousContentIntoBackupDirectory() throws {
        try Data("version-1".utf8).write(to: vaultFileURL)
        let bookmark = try LocalFileVaultStore.createFileBookmark(for: vaultFileURL)
        let store = try makeStore(bookmark: bookmark)

        try store.save(data: Data("version-2".utf8))

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupDir.path))
        let backups = try FileManager.default.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), Data("version-1".utf8))
    }

    func testSaveRotatesBackupsKeepingOnlyBackupCount() throws {
        try Data("version-0".utf8).write(to: vaultFileURL)
        let bookmark = try LocalFileVaultStore.createFileBookmark(for: vaultFileURL)
        let store = try LocalFileVaultStore(bookmarkData: bookmark, localBackupDirectory: backupDir, backupCount: 2)

        for version in 1...4 {
            try store.save(data: Data("version-\(version)".utf8))
        }

        let backups = try FileManager.default.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 2, "expected rotation to keep only the last backupCount snapshots")
    }
}
