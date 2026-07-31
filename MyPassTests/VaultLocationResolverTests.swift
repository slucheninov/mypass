import XCTest
@testable import MyPass

final class VaultLocationResolverTests: XCTestCase {
    func testResolveVaultLocationDefaultsToLocalForNilOrUnknown() {
        XCTAssertEqual(VaultLocationResolver.resolveVaultLocation(rawValue: nil), .local)
        XCTAssertEqual(VaultLocationResolver.resolveVaultLocation(rawValue: "garbage"), .local)
        XCTAssertEqual(VaultLocationResolver.resolveVaultLocation(rawValue: "iCloud Drive"), .iCloudDrive)
    }

    func testMigrateLegacyBackendReturnsNilWhenNothingLegacyIsConfigured() {
        XCTAssertNil(VaultLocationResolver.migrateLegacyBackendIfNeeded(
            legacySyncBackendRawValue: nil, legacyLocalFolderBookmark: nil
        ))
    }

    func testMigrateLegacyICloudBackendPromotesToDrivePrimaryWhenICloudIsNewer() throws {
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        let result = try XCTUnwrap(VaultLocationResolver.migrateLegacyBackendIfNeeded(
            legacySyncBackendRawValue: "iCloud Drive",
            legacyLocalFolderBookmark: nil,
            localVaultModificationDate: older,
            iCloudVaultModificationDate: newer
        ))
        XCTAssertEqual(result.vaultLocation, .iCloudDrive)
        XCTAssertNil(result.secondaryDestination)
        XCTAssertNil(result.secondaryFolderBookmark)
    }

    func testMigrateLegacyICloudBackendPromotesToDrivePrimaryWhenDatesAreEqual() throws {
        let same = Date(timeIntervalSince1970: 1000)
        let result = try XCTUnwrap(VaultLocationResolver.migrateLegacyBackendIfNeeded(
            legacySyncBackendRawValue: "iCloud Drive",
            legacyLocalFolderBookmark: nil,
            localVaultModificationDate: same,
            iCloudVaultModificationDate: same
        ))
        XCTAssertEqual(result.vaultLocation, .iCloudDrive)
    }

    func testMigrateLegacyICloudBackendStaysLocalWhenLocalCopyIsNewer() throws {
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        let iCloudBookmark = Data("fake-icloud-bookmark".utf8)
        let result = try XCTUnwrap(VaultLocationResolver.migrateLegacyBackendIfNeeded(
            legacySyncBackendRawValue: "iCloud Drive",
            legacyLocalFolderBookmark: nil,
            legacyICloudFolderBookmark: iCloudBookmark,
            localVaultModificationDate: newer,
            iCloudVaultModificationDate: older
        ))
        XCTAssertEqual(result.vaultLocation, .local)
        XCTAssertEqual(result.secondaryDestination, .folder)
        XCTAssertEqual(result.secondaryFolderBookmark, iCloudBookmark)
    }

    func testMigrateLegacyICloudBackendStaysLocalWhenICloudDateIsUnavailable() throws {
        let iCloudBookmark = Data("fake-icloud-bookmark".utf8)
        let result = try XCTUnwrap(VaultLocationResolver.migrateLegacyBackendIfNeeded(
            legacySyncBackendRawValue: "iCloud Drive",
            legacyLocalFolderBookmark: nil,
            legacyICloudFolderBookmark: iCloudBookmark,
            localVaultModificationDate: Date(),
            iCloudVaultModificationDate: nil
        ))
        XCTAssertEqual(result.vaultLocation, .local)
        XCTAssertEqual(result.secondaryDestination, .folder)
        XCTAssertEqual(result.secondaryFolderBookmark, iCloudBookmark)
    }

    func testMigrateLegacyLocalFolderBackendBecomesFolderSecondary() throws {
        let bookmark = Data("fake-bookmark".utf8)
        let result = try XCTUnwrap(VaultLocationResolver.migrateLegacyBackendIfNeeded(
            legacySyncBackendRawValue: "Local File", legacyLocalFolderBookmark: bookmark
        ))
        XCTAssertEqual(result.vaultLocation, .local)
        XCTAssertEqual(result.secondaryDestination, .folder)
        XCTAssertEqual(result.secondaryFolderBookmark, bookmark)
    }

    func testMigrateLegacySFTPBackendBecomesSFTPSecondary() throws {
        let result = try XCTUnwrap(VaultLocationResolver.migrateLegacyBackendIfNeeded(
            legacySyncBackendRawValue: "SFTP", legacyLocalFolderBookmark: nil
        ))
        XCTAssertEqual(result.vaultLocation, .local)
        XCTAssertEqual(result.secondaryDestination, .sftp)
        XCTAssertNil(result.secondaryFolderBookmark)
    }

    func testMigrateUnrecognizedLegacyValueFallsBackToLocalWithNoSecondary() throws {
        let result = try XCTUnwrap(VaultLocationResolver.migrateLegacyBackendIfNeeded(
            legacySyncBackendRawValue: "something-unexpected", legacyLocalFolderBookmark: nil
        ))
        XCTAssertEqual(result.vaultLocation, .local)
        XCTAssertNil(result.secondaryDestination)
    }
}
