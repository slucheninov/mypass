import XCTest
@testable import MyPass

final class VaultPrimaryStoreResolverTests: XCTestCase {
    private var applicationSupportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("VaultPrimaryStoreResolverTests")
    }

    func testLocalLocationAlwaysResolvesToVaultFileStoreWithNoFallback() {
        let resolution = VaultPrimaryStoreResolver.resolvePrimaryStore(
            vaultLocation: .local,
            applicationSupportDirectory: applicationSupportDirectory,
            iCloudBookmarkData: nil,
            localVaultFileBookmarkData: nil,
            makeICloudStore: { _ in XCTFail("must not attempt iCloud construction for .local"); return nil },
            makeLocalFileStore: { _ in nil }
        )
        XCTAssertTrue(resolution.primaryStore is VaultFileStore)
        XCTAssertFalse(resolution.iCloudFallbackToLocal)
        XCTAssertFalse(resolution.localFileFallbackActive)
    }

    func testICloudLocationWithWorkingBookmarkUsesTheICloudStoreNoFallback() {
        let folder = applicationSupportDirectory.appendingPathComponent("icloud-folder")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }
        guard let bookmark = try? bookmarkData(for: folder) else {
            return XCTFail("could not create test bookmark")
        }
        let expectedStore = try? ICloudDriveVaultStore(
            bookmarkData: bookmark,
            localBackupDirectory: applicationSupportDirectory.appendingPathComponent("backups")
        )

        let resolution = VaultPrimaryStoreResolver.resolvePrimaryStore(
            vaultLocation: .iCloudDrive,
            applicationSupportDirectory: applicationSupportDirectory,
            iCloudBookmarkData: bookmark,
            localVaultFileBookmarkData: nil,
            makeICloudStore: { _ in expectedStore },
            makeLocalFileStore: { _ in nil }
        )
        XCTAssertTrue(resolution.primaryStore is ICloudDriveVaultStore)
        XCTAssertFalse(resolution.iCloudFallbackToLocal)
    }

    func testICloudLocationWithMissingBookmarkFallsBackToLocal() {
        let resolution = VaultPrimaryStoreResolver.resolvePrimaryStore(
            vaultLocation: .iCloudDrive,
            applicationSupportDirectory: applicationSupportDirectory,
            iCloudBookmarkData: nil,
            localVaultFileBookmarkData: nil,
            makeICloudStore: { _ in XCTFail("must not attempt construction with no bookmark data"); return nil },
            makeLocalFileStore: { _ in nil }
        )
        XCTAssertTrue(resolution.primaryStore is VaultFileStore)
        XCTAssertTrue(resolution.iCloudFallbackToLocal)
    }

    func testICloudLocationWithUnresolvableBookmarkFallsBackToLocal() {
        let resolution = VaultPrimaryStoreResolver.resolvePrimaryStore(
            vaultLocation: .iCloudDrive,
            applicationSupportDirectory: applicationSupportDirectory,
            iCloudBookmarkData: Data("stale-or-unresolvable".utf8),
            localVaultFileBookmarkData: nil,
            makeICloudStore: { _ in nil },
            makeLocalFileStore: { _ in nil }
        )
        XCTAssertTrue(resolution.primaryStore is VaultFileStore)
        XCTAssertTrue(resolution.iCloudFallbackToLocal)
    }

    func testICloudLocationWithEmptyBookmarkDataFallsBackToLocal() {
        let resolution = VaultPrimaryStoreResolver.resolvePrimaryStore(
            vaultLocation: .iCloudDrive,
            applicationSupportDirectory: applicationSupportDirectory,
            iCloudBookmarkData: Data(),
            localVaultFileBookmarkData: nil,
            makeICloudStore: { _ in XCTFail("must not attempt construction with empty bookmark data"); return nil },
            makeLocalFileStore: { _ in nil }
        )
        XCTAssertTrue(resolution.primaryStore is VaultFileStore)
        XCTAssertTrue(resolution.iCloudFallbackToLocal)
    }

    func testLocalLocationWithValidFileBookmarkUsesLocalFileVaultStore() throws {
        let vaultFile = applicationSupportDirectory.appendingPathComponent("opened.kdbx")
        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        try Data("opened".utf8).write(to: vaultFile)
        let bookmark = try LocalFileVaultStore.createFileBookmark(for: vaultFile)
        let backupDir = applicationSupportDirectory.appendingPathComponent("backups")
        let expectedStore = try LocalFileVaultStore(bookmarkData: bookmark, localBackupDirectory: backupDir)

        let resolution = VaultPrimaryStoreResolver.resolvePrimaryStore(
            vaultLocation: .local,
            applicationSupportDirectory: applicationSupportDirectory,
            iCloudBookmarkData: nil,
            localVaultFileBookmarkData: bookmark,
            makeICloudStore: { _ in XCTFail("must not attempt iCloud for .local"); return nil },
            makeLocalFileStore: { data in try? LocalFileVaultStore(bookmarkData: data, localBackupDirectory: backupDir) }
        )
        XCTAssertTrue(resolution.primaryStore is LocalFileVaultStore)
        XCTAssertFalse(resolution.iCloudFallbackToLocal)
        XCTAssertFalse(resolution.localFileFallbackActive)
        XCTAssertEqual(
            resolution.primaryStore.primaryVaultFileURL?.path,
            expectedStore.primaryVaultFileURL?.path
        )
    }

    func testLocalLocationWithoutFileBookmarkUsesApplicationSupportVaultFileStore() {
        let resolution = VaultPrimaryStoreResolver.resolvePrimaryStore(
            vaultLocation: .local,
            applicationSupportDirectory: applicationSupportDirectory,
            iCloudBookmarkData: nil,
            localVaultFileBookmarkData: nil,
            makeICloudStore: { _ in XCTFail("must not attempt iCloud for .local"); return nil },
            makeLocalFileStore: { _ in XCTFail("must not attempt file bookmark store without data"); return nil }
        )
        XCTAssertTrue(resolution.primaryStore is VaultFileStore)
        XCTAssertFalse(resolution.primaryStore is LocalFileVaultStore)
        XCTAssertFalse(resolution.iCloudFallbackToLocal)
        XCTAssertFalse(resolution.localFileFallbackActive)
    }

    /// Finding 6: a local file bookmark WAS configured (the user had done
    /// "Open Existing…" before) but no longer resolves — stale, access
    /// denied, or the file was moved/deleted. Falling back to Application
    /// Support silently, with no signal distinguishing this from the normal
    /// "never configured a bookmark" case, left Settings showing the App
    /// Support path as if it were the user's real file with no warning.
    func testLocalLocationWithUnresolvableFileBookmarkFallsBackWithWarningFlag() {
        let resolution = VaultPrimaryStoreResolver.resolvePrimaryStore(
            vaultLocation: .local,
            applicationSupportDirectory: applicationSupportDirectory,
            iCloudBookmarkData: nil,
            localVaultFileBookmarkData: Data("stale-or-unresolvable".utf8),
            makeICloudStore: { _ in XCTFail("must not attempt iCloud for .local"); return nil },
            makeLocalFileStore: { _ in nil }
        )
        XCTAssertTrue(resolution.primaryStore is VaultFileStore)
        XCTAssertFalse(resolution.primaryStore is LocalFileVaultStore)
        XCTAssertFalse(resolution.iCloudFallbackToLocal)
        XCTAssertTrue(
            resolution.localFileFallbackActive,
            "a configured-but-unresolvable local file bookmark must be flagged distinctly from 'no bookmark configured at all'"
        )
    }

    private func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
