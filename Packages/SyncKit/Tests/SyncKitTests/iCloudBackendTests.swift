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
            "set MYPASS_ICLOUD_INTEGRATION_TESTS=1 (on a machine signed into iCloud with Drive enabled, running the signed MyPass test bundle) to run tests against a real ubiquity container"
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
