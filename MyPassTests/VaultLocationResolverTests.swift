import XCTest
@testable import MyPass

final class VaultLocationResolverTests: XCTestCase {
    func testResolveVaultLocationDefaultsToLocalForNilOrUnknown() {
        XCTAssertEqual(VaultLocationResolver.resolveVaultLocation(rawValue: nil), .local)
        XCTAssertEqual(VaultLocationResolver.resolveVaultLocation(rawValue: "garbage"), .local)
        XCTAssertEqual(VaultLocationResolver.resolveVaultLocation(rawValue: "iCloud Drive"), .iCloudDrive)
    }

    func testShouldShowFirstRunWizardOnlyForTrulyFreshInstall() {
        XCTAssertTrue(VaultLocationResolver.shouldShowFirstRunWizard(
            vaultLocationRawValue: nil, legacySyncBackendRawValue: nil, applicationSupportVaultExists: false
        ))
        XCTAssertFalse(VaultLocationResolver.shouldShowFirstRunWizard(
            vaultLocationRawValue: "Local File", legacySyncBackendRawValue: nil, applicationSupportVaultExists: false
        ))
        XCTAssertFalse(VaultLocationResolver.shouldShowFirstRunWizard(
            vaultLocationRawValue: nil, legacySyncBackendRawValue: "iCloud Drive", applicationSupportVaultExists: false
        ))
        XCTAssertFalse(VaultLocationResolver.shouldShowFirstRunWizard(
            vaultLocationRawValue: nil, legacySyncBackendRawValue: nil, applicationSupportVaultExists: true
        ))
    }

    func testMigrateLegacyBackendReturnsNilWhenNothingLegacyIsConfigured() {
        XCTAssertNil(VaultLocationResolver.migrateLegacyBackendIfNeeded(
            legacySyncBackendRawValue: nil, legacyLocalFolderBookmark: nil
        ))
    }

    func testMigrateLegacyICloudBackendPromotesToDrivePrimary() throws {
        let result = try XCTUnwrap(VaultLocationResolver.migrateLegacyBackendIfNeeded(
            legacySyncBackendRawValue: "iCloud Drive", legacyLocalFolderBookmark: nil
        ))
        XCTAssertEqual(result.vaultLocation, .iCloudDrive)
        XCTAssertNil(result.secondaryDestination)
        XCTAssertNil(result.secondaryFolderBookmark)
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
