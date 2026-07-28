import XCTest
import SyncKit
@testable import MyPass

/// The migration sheet's user-facing copy carries safety guarantees, so the
/// wording of the branches that matter is asserted rather than trusted.
final class SyncMigrationSheetMessageTests: XCTestCase {
    func testLocalWriteFailureSaysTheCloudCopyIsAhead() {
        struct Boom: Error {}
        let message = SyncMigrationSheet.message(for: VaultMigrationError.localWriteFailed(underlying: Boom()))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("ahead"), message)
    }

    func testPasswordMismatchSaysNothingChanged() {
        let message = SyncMigrationSheet.message(for: VaultMigrationError.remotePasswordMismatch)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("different password"), message)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("nothing was changed"), message)
    }

    func testInvalidRemoteVaultSaysNothingChanged() {
        let message = SyncMigrationSheet.message(for: VaultMigrationError.remoteNotAValidVault)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("nothing was changed"), message)
    }

    func testRemoteWriteFailureSaysTheLocalVaultIsIntact() {
        struct Boom: Error {}
        let message = SyncMigrationSheet.message(for: VaultMigrationError.remoteWriteFailed(underlying: Boom()))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("local vault was not changed"), message)
    }

    func testDownloadTimeoutOffersToWaitAndRetry() {
        let message = SyncMigrationSheet.message(for: iCloudBackendError.downloadTimedOut)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("still downloading"), message)
    }

    func testNoMessageMentionsSigningIntoICloud() {
        let errors: [Error] = [
            iCloudBackendError.containerUnavailable,
            iCloudBackendError.folderUnavailable,
            iCloudBackendError.folderBookmarkUnresolvable,
            iCloudBackendError.downloadTimedOut,
            VaultMigrationError.vaultLocked,
            VaultMigrationError.remoteNotAValidVault,
            VaultMigrationError.remotePasswordMismatch,
            VaultMigrationError.serializedVaultInvalid
        ]
        for error in errors {
            let message = SyncMigrationSheet.message(for: error)
            XCTAssertFalse(message.localizedCaseInsensitiveContains("sign in to iCloud"), message)
        }
    }

    func testMergeIsDescribedAsKeepingBothSides() {
        let explanation = SyncMigrationSheet.explanation(for: .merge)
        XCTAssertTrue(explanation.localizedCaseInsensitiveContains("both sides"), explanation)
    }

    func testProbeDescriptionIncludesSizeAndDate() {
        let probe = VaultMigrationTargetProbe(
            exists: true,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            byteCount: 4096
        )
        let description = SyncMigrationSheet.describe(probe)
        XCTAssertTrue(description.contains("KB"), description)
        XCTAssertTrue(description.localizedCaseInsensitiveContains("modified"), description)
    }

    func testProbeDescriptionIsEmptyWithoutMetadata() {
        let probe = VaultMigrationTargetProbe(exists: true, modificationDate: nil, byteCount: nil)
        XCTAssertEqual(SyncMigrationSheet.describe(probe), "")
    }
}
