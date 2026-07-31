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
            makeICloudStore: { _ in XCTFail("must not attempt iCloud construction for .local"); return nil }
        )
        XCTAssertTrue(resolution.primaryStore is VaultFileStore)
        XCTAssertFalse(resolution.iCloudFallbackToLocal)
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
            makeICloudStore: { _ in expectedStore }
        )
        XCTAssertTrue(resolution.primaryStore is ICloudDriveVaultStore)
        XCTAssertFalse(resolution.iCloudFallbackToLocal)
    }

    func testICloudLocationWithMissingBookmarkFallsBackToLocal() {
        let resolution = VaultPrimaryStoreResolver.resolvePrimaryStore(
            vaultLocation: .iCloudDrive,
            applicationSupportDirectory: applicationSupportDirectory,
            iCloudBookmarkData: nil,
            makeICloudStore: { _ in XCTFail("must not attempt construction with no bookmark data"); return nil }
        )
        XCTAssertTrue(resolution.primaryStore is VaultFileStore)
        XCTAssertTrue(resolution.iCloudFallbackToLocal)
    }

    func testICloudLocationWithUnresolvableBookmarkFallsBackToLocal() {
        let resolution = VaultPrimaryStoreResolver.resolvePrimaryStore(
            vaultLocation: .iCloudDrive,
            applicationSupportDirectory: applicationSupportDirectory,
            iCloudBookmarkData: Data("stale-or-unresolvable".utf8),
            makeICloudStore: { _ in nil }
        )
        XCTAssertTrue(resolution.primaryStore is VaultFileStore)
        XCTAssertTrue(resolution.iCloudFallbackToLocal)
    }

    func testICloudLocationWithEmptyBookmarkDataFallsBackToLocal() {
        let resolution = VaultPrimaryStoreResolver.resolvePrimaryStore(
            vaultLocation: .iCloudDrive,
            applicationSupportDirectory: applicationSupportDirectory,
            iCloudBookmarkData: Data(),
            makeICloudStore: { _ in XCTFail("must not attempt construction with empty bookmark data"); return nil }
        )
        XCTAssertTrue(resolution.primaryStore is VaultFileStore)
        XCTAssertTrue(resolution.iCloudFallbackToLocal)
    }

    private func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
