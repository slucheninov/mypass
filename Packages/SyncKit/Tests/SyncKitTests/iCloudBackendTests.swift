import XCTest
@testable import SyncKit

/// End-to-end tests against a REAL iCloud Drive ubiquity container. These
/// require a machine signed into iCloud with Drive enabled and the test
/// bundle's entitlements to include the app's iCloud container — neither is
/// available in a typical CI runner, so this class is gated behind
/// `MYPASS_ICLOUD_INTEGRATION_TESTS=1`, following this plan's existing
/// convention (Task 9's `MYPASS_KEYCHAIN_TESTS`, Task 10's
/// `MYPASS_SFTP_INTEGRATION_TESTS`).
final class iCloudBackendTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MYPASS_ICLOUD_INTEGRATION_TESTS"] == "1",
            "set MYPASS_ICLOUD_INTEGRATION_TESTS=1 (on a machine signed into iCloud with Drive enabled) to run tests against a real ubiquity container and a real iCloud Drive folder"
        )
    }

    func testWriteThenReadRoundTripsExactBytes() throws {
        let backend = try iCloudBackend(relativePath: "mypass-icloud-backend-tests-\(UUID().uuidString).kdbx")
        let payload = Data("icloud-round-trip-bytes".utf8)
        try backend.write(payload)
        XCTAssertTrue(try backend.exists())
        XCTAssertEqual(try backend.read(), payload)
    }

    func testModificationDateIsNonNilAfterWriteAndIncreasesOnSecondWrite() throws {
        let backend = try iCloudBackend(relativePath: "mypass-icloud-backend-tests-\(UUID().uuidString).kdbx")
        try backend.write(Data("v1".utf8))
        let firstDate = try XCTUnwrap(backend.modificationDate())

        Thread.sleep(forTimeInterval: 1.1)
        try backend.write(Data("v2".utf8))
        let secondDate = try XCTUnwrap(backend.modificationDate())

        XCTAssertGreaterThan(secondDate, firstDate)
    }

    func testEnsureDownloadedSucceedsForAFileWrittenByThisProcess() throws {
        let backend = try iCloudBackend(relativePath: "mypass-icloud-backend-tests-\(UUID().uuidString).kdbx")
        try backend.write(Data("already local, never actually offloaded".utf8))
        XCTAssertNoThrow(try backend.ensureDownloaded(timeout: 5))
    }

    func testExistsIsFalseBeforeAnyWrite() throws {
        let backend = try iCloudBackend(relativePath: "mypass-icloud-backend-tests-\(UUID().uuidString).kdbx")
        XCTAssertFalse(try backend.exists())
        XCTAssertNil(try backend.read())
    }

    func testResolveConflictVersionsReturnsFalseWhenNoConflictsExist() throws {
        let backend = try iCloudBackend(relativePath: "mypass-icloud-backend-tests-\(UUID().uuidString).kdbx")
        try backend.write(Data("no conflicts here".utf8))

        var mergeCalled = false
        let resolved = try backend.resolveConflictVersions { current, _ in
            mergeCalled = true
            return current
        }

        XCTAssertFalse(resolved)
        XCTAssertFalse(mergeCalled)
    }

    func testUserFolderRootRoundTripsInsideRealICloudDrive() throws {
        let root = try XCTUnwrap(ICloudDriveLocation.iCloudDriveRootURL)
        let folder = root.appendingPathComponent("MyPassICloudBackendTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let bookmark = try iCloudBackend.createFolderBookmark(for: folder)
        let backend = try iCloudBackend(root: .userFolder(bookmark: bookmark), relativePath: "vault.kdbx")

        XCTAssertFalse(try backend.exists())
        let payload = Data("real-icloud-drive-folder-round-trip".utf8)
        try backend.write(payload)
        XCTAssertTrue(try backend.exists())
        XCTAssertEqual(try backend.read(), payload)
        XCTAssertNotNil(try backend.modificationDate())
    }
}

/// Pure/unit tests that do NOT touch a real ubiquity container — always run,
/// regardless of `MYPASS_ICLOUD_INTEGRATION_TESTS`, in a separate class so
/// this class's `setUp()` (no gate) is independent of `iCloudBackendTests`'s
/// gated `setUpWithError()` above.
final class iCloudBackendUngatedTests: XCTestCase {
    func testInitThrowsContainerUnavailableWithBogusIdentifier() {
        XCTAssertThrowsError(
            try iCloudBackend(relativePath: "vault.kdbx", containerIdentifier: "iCloud.com.mypass.definitely-not-a-real-container-id")
        ) { error in
            XCTAssertEqual(error as? iCloudBackendError, .containerUnavailable)
        }
    }

    func testCoordinatedURLAppendsDocumentsAndRelativePath() {
        let container = URL(fileURLWithPath: "/tmp/fake-ubiquity-container")
        let url = iCloudBackend.coordinatedURL(containerURL: container, relativePath: "vault.kdbx")
        XCTAssertEqual(url.path, "/tmp/fake-ubiquity-container/Documents/vault.kdbx")
    }

    func testCoordinatedURLHandlesNestedRelativePaths() {
        let container = URL(fileURLWithPath: "/tmp/fake-ubiquity-container")
        let url = iCloudBackend.coordinatedURL(containerURL: container, relativePath: "backups/vault-2026.kdbx")
        XCTAssertEqual(url.path, "/tmp/fake-ubiquity-container/Documents/backups/vault-2026.kdbx")
    }
}

/// `.userFolder` root tests. These need no iCloud account: the root is a
/// temporary directory reached through a real security-scoped bookmark, and
/// every code path except `ensureDownloaded`'s materialisation poll is shared
/// with the ubiquity-container root.
final class iCloudBackendUserFolderTests: XCTestCase {
    var tempDir: URL!
    var bookmark: Data!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncKitICloudUserFolderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        bookmark = try iCloudBackend.createFolderBookmark(for: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCoordinatedURLForUserFolderHasNoDocumentsComponent() {
        let folder = URL(fileURLWithPath: "/tmp/fake-icloud-drive-folder")
        let url = iCloudBackend.coordinatedURL(folderURL: folder, relativePath: "vault.kdbx")
        XCTAssertEqual(url.path, "/tmp/fake-icloud-drive-folder/vault.kdbx")
    }

    func testExistsIsFalseBeforeAnyWrite() throws {
        let backend = try iCloudBackend(root: .userFolder(bookmark: bookmark), relativePath: "vault.kdbx")
        XCTAssertFalse(try backend.exists())
        XCTAssertNil(try backend.read())
        XCTAssertNil(try backend.modificationDate())
    }

    func testWriteThenReadRoundTripsExactBytes() throws {
        let backend = try iCloudBackend(root: .userFolder(bookmark: bookmark), relativePath: "vault.kdbx")
        let payload = Data("icloud-user-folder-round-trip".utf8)
        try backend.write(payload)
        XCTAssertTrue(try backend.exists())
        XCTAssertEqual(try backend.read(), payload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("vault.kdbx").path))
    }

    func testWriteCreatesIntermediateDirectoriesForNestedRelativePath() throws {
        let backend = try iCloudBackend(root: .userFolder(bookmark: bookmark), relativePath: "MyPass/vault.kdbx")
        try backend.write(Data("nested".utf8))
        XCTAssertEqual(try backend.read(), Data("nested".utf8))
    }

    func testSecondWriteOverwritesFirstAndAdvancesModificationDate() throws {
        let backend = try iCloudBackend(root: .userFolder(bookmark: bookmark), relativePath: "vault.kdbx")
        try backend.write(Data("v1".utf8))
        let firstDate = try XCTUnwrap(backend.modificationDate())

        Thread.sleep(forTimeInterval: 1.1)
        try backend.write(Data("v2".utf8))
        let secondDate = try XCTUnwrap(backend.modificationDate())

        XCTAssertEqual(try backend.read(), Data("v2".utf8))
        XCTAssertGreaterThan(secondDate, firstDate)
    }

    func testEnsureDownloadedIsANoOpForANonUbiquitousFile() throws {
        let backend = try iCloudBackend(root: .userFolder(bookmark: bookmark), relativePath: "vault.kdbx")
        try backend.write(Data("plain local file, not managed by iCloud".utf8))
        XCTAssertNoThrow(try backend.ensureDownloaded(timeout: 1))
    }

    func testResolveConflictVersionsReturnsFalseWhenNoConflictsExist() throws {
        let backend = try iCloudBackend(root: .userFolder(bookmark: bookmark), relativePath: "vault.kdbx")
        try backend.write(Data("no conflicts here".utf8))

        var mergeCalled = false
        let resolved = try backend.resolveConflictVersions { current, _ in
            mergeCalled = true
            return current
        }

        XCTAssertFalse(resolved)
        XCTAssertFalse(mergeCalled)
    }

    func testInitThrowsFolderBookmarkUnresolvableForEmptyBookmark() {
        XCTAssertThrowsError(try iCloudBackend(root: .userFolder(bookmark: Data()), relativePath: "vault.kdbx")) { error in
            XCTAssertEqual(error as? iCloudBackendError, .folderBookmarkUnresolvable)
        }
    }

    func testInitThrowsFolderBookmarkUnresolvableForGarbageBookmark() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE])
        XCTAssertThrowsError(try iCloudBackend(root: .userFolder(bookmark: garbage), relativePath: "vault.kdbx")) { error in
            XCTAssertEqual(error as? iCloudBackendError, .folderBookmarkUnresolvable)
        }
    }

    func testInitThrowsFolderUnavailableWhenBookmarkPointsAtAFile() throws {
        let fileURL = tempDir.appendingPathComponent("not-a-folder.txt")
        try Data("x".utf8).write(to: fileURL)
        let fileBookmark = try iCloudBackend.createFolderBookmark(for: fileURL)

        XCTAssertThrowsError(try iCloudBackend(root: .userFolder(bookmark: fileBookmark), relativePath: "vault.kdbx")) { error in
            XCTAssertEqual(error as? iCloudBackendError, .folderUnavailable)
        }
    }

    func testUbiquityConvenienceInitStillThrowsContainerUnavailableWithoutEntitlements() {
        XCTAssertThrowsError(
            try iCloudBackend(relativePath: "vault.kdbx", containerIdentifier: "iCloud.com.mypass.definitely-not-a-real-container-id")
        ) { error in
            XCTAssertEqual(error as? iCloudBackendError, .containerUnavailable)
        }
    }
}
