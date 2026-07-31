import XCTest
import SyncKit
@testable import MyPass

final class SettingsViewSyncBackendTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsViewSyncBackendTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testResolveLocalFolderBackendReturnsWorkingBackendForValidBookmark() throws {
        let bookmark = try LocalFolderBackend.createBookmark(for: tempDir)
        let backend = SyncBackendResolver.resolveLocalFolderBackend(bookmarkData: bookmark)
        let resolved = try XCTUnwrap(backend)

        XCTAssertFalse(try resolved.exists())
        try resolved.write(Data("resolved-backend-round-trip".utf8))
        XCTAssertEqual(try resolved.read(), Data("resolved-backend-round-trip".utf8))
    }

    func testResolveLocalFolderBackendReturnsNilForMissingBookmark() {
        XCTAssertNil(SyncBackendResolver.resolveLocalFolderBackend(bookmarkData: nil))
        XCTAssertNil(SyncBackendResolver.resolveLocalFolderBackend(bookmarkData: Data()))
    }

    func testResolveLocalFolderBackendReturnsNilForInvalidBookmarkDataWithoutCrashing() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE])
        XCTAssertNil(SyncBackendResolver.resolveLocalFolderBackend(bookmarkData: garbage))
    }

    func testBuildSFTPConfigurationCombinesStoredFieldsWithLoadedCredentials() throws {
        let credentials = SFTPCredentials(
            username: "vault-user",
            privateKeyPEM: "-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----",
            privateKeyPassphrase: "hunter2"
        )

        let configuration = try XCTUnwrap(SyncBackendResolver.buildSFTPConfiguration(
            host: "sftp.example.com",
            port: 2222,
            username: "ignored-form-field-username",
            remotePath: "/upload/vault.kdbx",
            credentials: credentials
        ))

        XCTAssertEqual(configuration.host, "sftp.example.com")
        XCTAssertEqual(configuration.port, 2222)
        // The username actually used comes from the loaded Keychain
        // credentials, not the (possibly stale) form field — Keychain is
        // the single source of truth for anything paired with the private
        // key, since a mismatched username would silently fail auth.
        XCTAssertEqual(configuration.username, "vault-user")
        XCTAssertEqual(configuration.remotePath, "/upload/vault.kdbx")
        XCTAssertEqual(configuration.privateKeyPEM, credentials.privateKeyPEM)
        XCTAssertEqual(configuration.privateKeyPassphrase, "hunter2")
    }

    func testBuildSFTPConfigurationReturnsNilWithoutCredentials() {
        XCTAssertNil(SyncBackendResolver.buildSFTPConfiguration(
            host: "sftp.example.com",
            port: 22,
            username: "someone",
            remotePath: "/upload/vault.kdbx",
            credentials: nil
        ))
    }

    func testBuildSFTPConfigurationReturnsNilWithEmptyHost() {
        let credentials = SFTPCredentials(username: "u", privateKeyPEM: "pem", privateKeyPassphrase: nil)
        XCTAssertNil(SyncBackendResolver.buildSFTPConfiguration(
            host: "",
            port: 22,
            username: "u",
            remotePath: "/upload/vault.kdbx",
            credentials: credentials
        ))
    }

    func testSFTPConnectionTesterReturnsSuccessWhenBackendDoesNotThrow() {
        struct AlwaysExistsBackend: StorageBackend {
            func read() throws -> Data? { nil }
            func write(_ data: Data) throws {}
            func modificationDate() throws -> Date? { nil }
            func exists() throws -> Bool { true }
        }

        let configuration = SFTPBackendConfiguration(
            host: "sftp.example.com", username: "u", remotePath: "/upload/vault.kdbx", privateKeyPEM: "pem"
        )
        let tester = SFTPConnectionTester(
            configurationProvider: { configuration },
            backendFactory: { _ in AlwaysExistsBackend() }
        )

        switch tester.testConnection() {
        case .success: break
        case .failure(let error): XCTFail("expected success, got \(error)")
        }
    }

    func testSFTPConnectionTesterReturnsFailureWhenBackendThrows() {
        struct ThrowingBackend: StorageBackend {
            struct Boom: Error {}
            func read() throws -> Data? { throw Boom() }
            func write(_ data: Data) throws { throw Boom() }
            func modificationDate() throws -> Date? { throw Boom() }
            func exists() throws -> Bool { throw Boom() }
        }

        let configuration = SFTPBackendConfiguration(
            host: "sftp.example.com", username: "u", remotePath: "/upload/vault.kdbx", privateKeyPEM: "pem"
        )
        let tester = SFTPConnectionTester(
            configurationProvider: { configuration },
            backendFactory: { _ in ThrowingBackend() }
        )

        switch tester.testConnection() {
        case .success: XCTFail("expected failure")
        case .failure: break
        }
    }

    func testSFTPConnectionTesterReturnsFailureWhenConfigurationIsMissing() {
        let tester = SFTPConnectionTester(configurationProvider: { nil })
        switch tester.testConnection() {
        case .success: XCTFail("expected failure")
        case .failure(let error):
            XCTAssertEqual(error as? SFTPConnectionTesterError, .missingConfiguration)
        }
    }

    func testResolveICloudBackendReturnsWorkingBackendForValidFolderBookmark() throws {
        let bookmark = try iCloudBackend.createFolderBookmark(for: tempDir)
        let resolved = try XCTUnwrap(SyncBackendResolver.resolveICloudBackend(bookmarkData: bookmark))

        XCTAssertFalse(try resolved.exists())
        try resolved.write(Data("icloud-resolver-round-trip".utf8))
        XCTAssertEqual(try resolved.read(), Data("icloud-resolver-round-trip".utf8))
    }

    func testResolveICloudBackendReturnsNilForMissingBookmark() {
        XCTAssertNil(SyncBackendResolver.resolveICloudBackend(bookmarkData: nil))
        XCTAssertNil(SyncBackendResolver.resolveICloudBackend(bookmarkData: Data()))
    }

    func testResolveICloudBackendReturnsNilForInvalidBookmarkDataWithoutCrashing() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE])
        XCTAssertNil(SyncBackendResolver.resolveICloudBackend(bookmarkData: garbage))
    }

    func testCheckpointKeyIsNamespacedPerSecondaryDestination() {
        XCTAssertEqual(SyncBackendResolver.checkpointKey(for: .folder), "com.mypass.sync.checkpoint.Folder")
        XCTAssertEqual(SyncBackendResolver.checkpointKey(for: .sftp), "com.mypass.sync.checkpoint.SFTP")
        XCTAssertNotEqual(
            SyncBackendResolver.checkpointKey(for: .folder),
            SyncBackendResolver.checkpointKey(for: .sftp)
        )
    }

    func testICloudFolderBookmarkKeyIsPinned() {
        // Pins the literal value: the Sync pane, the migration sheet, and app
        // launch wiring all read/write this key, so an accidental rename here
        // would silently reset every user's configured iCloud folder.
        XCTAssertEqual(SyncBackendResolver.iCloudFolderBookmarkKey, "syncICloudFolderBookmark")
    }

    func testClearCheckpointRemovesOnlyThatBackendsCheckpoint() throws {
        let suiteName = "com.mypass.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        defaults.set(1.0, forKey: SyncBackendResolver.checkpointKey(for: .folder))
        defaults.set(2.0, forKey: SyncBackendResolver.checkpointKey(for: .sftp))

        SyncBackendResolver.clearCheckpoint(for: .folder, defaults: defaults)

        XCTAssertNil(defaults.object(forKey: SyncBackendResolver.checkpointKey(for: .folder)))
        XCTAssertNotNil(defaults.object(forKey: SyncBackendResolver.checkpointKey(for: .sftp)))
    }
}
