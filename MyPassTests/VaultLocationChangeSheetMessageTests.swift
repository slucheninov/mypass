import XCTest
import SyncKit
@testable import MyPass

/// The vault location change sheet's user-facing copy carries safety
/// guarantees, so the wording of the branches that matter is asserted rather
/// than trusted.
final class VaultLocationChangeSheetMessageTests: XCTestCase {
    func testLocalWriteFailureSaysTheCloudCopyIsAhead() {
        struct Boom: Error {}
        let message = VaultLocationChangeSheet.message(for: VaultMigrationError.localWriteFailed(underlying: Boom()))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("ahead"), message)
    }

    func testPasswordMismatchSaysNothingChanged() {
        let message = VaultLocationChangeSheet.message(for: VaultMigrationError.remotePasswordMismatch)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("different password"), message)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("nothing was changed"), message)
    }

    func testInvalidRemoteVaultSaysNothingChanged() {
        let message = VaultLocationChangeSheet.message(for: VaultMigrationError.remoteNotAValidVault)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("nothing was changed"), message)
    }

    func testRemoteWriteFailureSaysTheLocalVaultIsIntact() {
        struct Boom: Error {}
        let message = VaultLocationChangeSheet.message(for: VaultMigrationError.remoteWriteFailed(underlying: Boom()))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("current vault was not changed"), message)
    }

    func testDownloadTimeoutOffersToWaitAndRetry() {
        let message = VaultLocationChangeSheet.message(for: iCloudBackendError.downloadTimedOut)
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
            let message = VaultLocationChangeSheet.message(for: error)
            XCTAssertFalse(message.localizedCaseInsensitiveContains("sign in to iCloud"), message)
        }
    }

    func testMergeIsDescribedAsKeepingBothSides() {
        let explanation = VaultLocationChangeSheet.explanation(for: .merge)
        XCTAssertTrue(explanation.localizedCaseInsensitiveContains("both sides"), explanation)
    }

    func testProbeDescriptionIncludesSizeAndDate() {
        let probe = VaultMigrationTargetProbe(
            exists: true,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            byteCount: 4096
        )
        let description = VaultLocationChangeSheet.describe(probe)
        XCTAssertTrue(description.contains("KB"), description)
        XCTAssertTrue(description.localizedCaseInsensitiveContains("modified"), description)
    }

    func testProbeDescriptionIsEmptyWithoutMetadata() {
        let probe = VaultMigrationTargetProbe(exists: true, modificationDate: nil, byteCount: nil)
        XCTAssertEqual(VaultLocationChangeSheet.describe(probe), "")
    }

    // MARK: - Download timeout unwrapping (wrapped by VaultMigrationService)

    func testRemoteWriteFailureFromDownloadTimeoutSaysStillDownloading() {
        let message = VaultLocationChangeSheet.message(
            for: VaultMigrationError.remoteWriteFailed(underlying: iCloudBackendError.downloadTimedOut)
        )
        XCTAssertTrue(message.localizedCaseInsensitiveContains("still downloading"), message)
        XCTAssertFalse(message.localizedCaseInsensitiveContains("could not write"), message)
    }

    func testRemoteUnreadableFromDownloadTimeoutSaysStillDownloading() {
        let message = VaultLocationChangeSheet.message(
            for: VaultMigrationError.remoteUnreadable(underlying: iCloudBackendError.downloadTimedOut)
        )
        XCTAssertTrue(message.localizedCaseInsensitiveContains("still downloading"), message)
        XCTAssertFalse(message.localizedCaseInsensitiveContains("could not read"), message)
    }

    func testRemoteWriteFailureFromNonBackendErrorKeepsGenericMessage() {
        struct Boom: Error {}
        let message = VaultLocationChangeSheet.message(for: VaultMigrationError.remoteWriteFailed(underlying: Boom()))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("current vault was not changed"), message)
    }

    // MARK: - shouldClearPersistedBookmark

    func testShouldClearPersistedBookmarkWhenFailingBookmarkMatchesPersisted() {
        let bookmark = Data("same-folder".utf8)
        XCTAssertTrue(VaultLocationChangeSheet.shouldClearPersistedBookmark(
            failingBookmark: bookmark,
            persistedBookmark: bookmark
        ))
    }

    func testShouldNotClearPersistedBookmarkWhenFailingBookmarkDiffersFromPersisted() {
        XCTAssertFalse(VaultLocationChangeSheet.shouldClearPersistedBookmark(
            failingBookmark: Data("candidate-folder".utf8),
            persistedBookmark: Data("working-folder".utf8)
        ))
    }

    func testShouldNotClearPersistedBookmarkWhenNoPersistedBookmarkExists() {
        XCTAssertFalse(VaultLocationChangeSheet.shouldClearPersistedBookmark(
            failingBookmark: Data("candidate-folder".utf8),
            persistedBookmark: nil
        ))
    }

    func testShouldNotClearPersistedBookmarkWhenFailingBookmarkIsNil() {
        XCTAssertFalse(VaultLocationChangeSheet.shouldClearPersistedBookmark(
            failingBookmark: nil,
            persistedBookmark: Data("working-folder".utf8)
        ))
    }

    // MARK: - needsPasswordConfirmation

    func testConfirmStepIsSkippedWhenAlreadyUnlocked() {
        XCTAssertFalse(VaultLocationChangeSheet.needsPasswordConfirmation(currentState: .unlocked))
    }

    func testConfirmStepIsRequiredWhenLocked() {
        XCTAssertTrue(VaultLocationChangeSheet.needsPasswordConfirmation(currentState: .locked))
    }

    // MARK: - destinationIsSameFileAsSource (Finding 1: self-move guard)

    /// The scenario the finding describes: the app silently fell back to the
    /// Application Support `VaultFileStore` (e.g. an unresolvable iCloud
    /// bookmark at launch) while Settings still offers "Move to Local…" —
    /// pressing it would otherwise construct the SAME file as both source
    /// and destination.
    func testDestinationIsSameFileAsSourceWhenBothResolveToTheSameFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultLocationChangeSheetMessageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceStore = VaultFileStore(directory: dir)
        let destinationBackend = VaultFileStore(directory: dir)

        XCTAssertTrue(VaultLocationChangeSheet.destinationIsSameFileAsSource(
            sourceStore: sourceStore,
            destinationBackend: destinationBackend
        ))
    }

    func testDestinationIsNotSameFileAsSourceForDifferentDirectories() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultLocationChangeSheetMessageTests-\(UUID().uuidString)")
        let sourceDir = base.appendingPathComponent("source")
        let destDir = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertFalse(VaultLocationChangeSheet.destinationIsSameFileAsSource(
            sourceStore: VaultFileStore(directory: sourceDir),
            destinationBackend: VaultFileStore(directory: destDir)
        ))
    }
}
