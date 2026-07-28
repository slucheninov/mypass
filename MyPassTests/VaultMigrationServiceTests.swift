import XCTest
import MyPassKit
import SyncKit
@testable import MyPass

final class VaultMigrationServiceTests: XCTestCase {
    var tempDir: URL!
    var fileStore: VaultFileStore!
    let password = "correct-horse"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultMigrationServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileStore = VaultFileStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixtures

    private func makeEntry(title: String, timestamp: Date = Date()) -> KdbxEntry {
        var entry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: timestamp,
            lastModificationTime: timestamp,
            lastAccessTime: timestamp,
            locationChanged: timestamp,
            history: []
        )
        entry.title = title
        return entry
    }

    private func makeDatabase(rootUUID: UUID, entryTitles: [String], timestamp: Date = Date()) -> KdbxDatabase {
        let rootGroup = KdbxGroup(
            uuid: rootUUID,
            name: "MyPass",
            iconID: 0,
            creationTime: timestamp,
            lastModificationTime: timestamp,
            locationChanged: timestamp,
            entries: entryTitles.map { makeEntry(title: $0, timestamp: timestamp) },
            subgroups: []
        )
        return KdbxDatabase(rootGroup: rootGroup, deletedObjects: [])
    }

    private func titles(inRemote remote: StorageBackend, password: String) throws -> Set<String> {
        let data = try XCTUnwrap(try remote.read())
        let database = try KdbxDatabase.open(data: data, password: password)
        return Set(database.rootGroup.entries.map { $0.title })
    }

    private func titlesOnDisk(password: String) throws -> Set<String> {
        let data = try XCTUnwrap(try fileStore.load())
        let database = try KdbxDatabase.open(data: data, password: password)
        return Set(database.rootGroup.entries.map { $0.title })
    }

    private var backupFileURLs: [URL] {
        let backups = tempDir.appendingPathComponent("backups")
        return (try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? []
    }

    // MARK: - Probe

    func testProbeReportsEmptyRemote() throws {
        let service = VaultMigrationService(fileStore: fileStore)
        let probe = try service.probe(remote: InMemoryStorageBackend())
        XCTAssertEqual(probe, VaultMigrationTargetProbe(exists: false, modificationDate: nil, byteCount: nil))
    }

    func testProbeReportsSizeAndDateForOccupiedRemote() throws {
        let remoteDatabase = makeDatabase(rootUUID: UUID(), entryTitles: ["Remote Only"])
        let remoteData = try remoteDatabase.save(password: password, cipher: .aes256, compression: .gzip)
        let remote = InMemoryStorageBackend(initialData: remoteData)

        let service = VaultMigrationService(fileStore: fileStore)
        let probe = try service.probe(remote: remote)

        XCTAssertTrue(probe.exists)
        XCTAssertEqual(probe.byteCount, remoteData.count)
        XCTAssertNotNil(probe.modificationDate)
    }

    func testProbeNeverNeedsThePassword() throws {
        let remoteDatabase = makeDatabase(rootUUID: UUID(), entryTitles: ["Remote Only"])
        let remoteData = try remoteDatabase.save(password: "a-totally-different-password", cipher: .aes256, compression: .gzip)
        let remote = InMemoryStorageBackend(initialData: remoteData)

        let service = VaultMigrationService(fileStore: fileStore)
        XCTAssertTrue(try service.probe(remote: remote).exists)
    }

    // MARK: - seedRemote

    func testSeedRemoteUploadsLocalVaultAndLeavesLocalFileUntouched() throws {
        let local = makeDatabase(rootUUID: UUID(), entryTitles: ["Local Only"])
        try fileStore.save(data: try local.save(password: password, cipher: .aes256, compression: .gzip))
        let localBytesBefore = try XCTUnwrap(try fileStore.load())
        let remote = InMemoryStorageBackend()

        let service = VaultMigrationService(fileStore: fileStore)
        let outcome = try service.migrate(local: local, password: password, remote: remote, strategy: .seedRemote)

        XCTAssertTrue(outcome.remoteWritten)
        XCTAssertFalse(outcome.localReplaced)
        XCTAssertNil(outcome.mergedDatabase)
        XCTAssertEqual(try titles(inRemote: remote, password: password), ["Local Only"])
        XCTAssertEqual(try fileStore.load(), localBytesBefore)
    }

    func testSeedRemoteReportsRemoteWriteFailureAndLeavesLocalUntouched() throws {
        struct SimulatedRemoteFailure: Error {}
        let local = makeDatabase(rootUUID: UUID(), entryTitles: ["Local Only"])
        try fileStore.save(data: try local.save(password: password, cipher: .aes256, compression: .gzip))
        let localBytesBefore = try XCTUnwrap(try fileStore.load())
        let remote = InMemoryStorageBackend()
        remote.writeError = SimulatedRemoteFailure()

        let service = VaultMigrationService(fileStore: fileStore)
        XCTAssertThrowsError(
            try service.migrate(local: local, password: password, remote: remote, strategy: .seedRemote)
        ) { error in
            guard case VaultMigrationError.remoteWriteFailed = error else {
                return XCTFail("expected remoteWriteFailed, got \(error)")
            }
        }
        XCTAssertEqual(try fileStore.load(), localBytesBefore)
        XCTAssertNil(try remote.read())
    }

    // MARK: - merge

    func testMergeKeepsEntriesFromBothSides() throws {
        let rootUUID = UUID()
        let local = makeDatabase(rootUUID: rootUUID, entryTitles: ["Local Only"])
        try fileStore.save(data: try local.save(password: password, cipher: .aes256, compression: .gzip))
        let remoteDatabase = makeDatabase(rootUUID: rootUUID, entryTitles: ["Remote Only"])
        let remote = InMemoryStorageBackend(
            initialData: try remoteDatabase.save(password: password, cipher: .aes256, compression: .gzip)
        )

        let service = VaultMigrationService(fileStore: fileStore)
        let outcome = try service.migrate(local: local, password: password, remote: remote, strategy: .merge)

        let merged = try XCTUnwrap(outcome.mergedDatabase)
        XCTAssertEqual(Set(merged.rootGroup.entries.map { $0.title }), ["Local Only", "Remote Only"])
        XCTAssertTrue(outcome.remoteWritten)
        XCTAssertTrue(outcome.localReplaced)
        XCTAssertEqual(try titlesOnDisk(password: password), ["Local Only", "Remote Only"])
        XCTAssertEqual(try titles(inRemote: remote, password: password), ["Local Only", "Remote Only"])
    }

    func testMergeLeavesLocalFileUntouchedWhenTheSyncPassFails() throws {
        struct SimulatedRemoteFailure: Error {}
        let rootUUID = UUID()
        let local = makeDatabase(rootUUID: rootUUID, entryTitles: ["Local Only"])
        try fileStore.save(data: try local.save(password: password, cipher: .aes256, compression: .gzip))
        let localBytesBefore = try XCTUnwrap(try fileStore.load())
        let remoteDatabase = makeDatabase(rootUUID: rootUUID, entryTitles: ["Remote Only"])
        let remote = InMemoryStorageBackend(
            initialData: try remoteDatabase.save(password: password, cipher: .aes256, compression: .gzip)
        )
        remote.writeError = SimulatedRemoteFailure()

        let service = VaultMigrationService(fileStore: fileStore)
        XCTAssertThrowsError(
            try service.migrate(local: local, password: password, remote: remote, strategy: .merge)
        )
        XCTAssertEqual(try fileStore.load(), localBytesBefore)
        XCTAssertTrue(backupFileURLs.isEmpty)
    }

    func testMergeWithWrongRemotePasswordLeavesBothSidesByteIdentical() throws {
        let rootUUID = UUID()
        let local = makeDatabase(rootUUID: rootUUID, entryTitles: ["Local Only"])
        try fileStore.save(data: try local.save(password: password, cipher: .aes256, compression: .gzip))
        let localBytesBefore = try XCTUnwrap(try fileStore.load())
        let remoteDatabase = makeDatabase(rootUUID: rootUUID, entryTitles: ["Remote Only"])
        let remoteBytesBefore = try remoteDatabase.save(
            password: "a-totally-different-password", cipher: .aes256, compression: .gzip
        )
        let remote = InMemoryStorageBackend(initialData: remoteBytesBefore)

        let service = VaultMigrationService(fileStore: fileStore)
        XCTAssertThrowsError(
            try service.migrate(local: local, password: password, remote: remote, strategy: .merge)
        ) { error in
            guard case VaultMigrationError.remotePasswordMismatch = error else {
                return XCTFail("expected remotePasswordMismatch, got \(error)")
            }
        }
        XCTAssertEqual(try fileStore.load(), localBytesBefore)
        XCTAssertEqual(try remote.read(), remoteBytesBefore)
        XCTAssertTrue(backupFileURLs.isEmpty)
    }

    // MARK: - adoptRemote

    func testAdoptRemoteReplacesLocalAndSnapshotsPreviousStateIntoBackups() throws {
        let local = makeDatabase(rootUUID: UUID(), entryTitles: ["Local Only"])
        try fileStore.save(data: try local.save(password: password, cipher: .aes256, compression: .gzip))
        let localBytesBefore = try XCTUnwrap(try fileStore.load())
        let remoteDatabase = makeDatabase(rootUUID: UUID(), entryTitles: ["Remote Only"])
        let remoteBytes = try remoteDatabase.save(password: password, cipher: .aes256, compression: .gzip)
        let remote = InMemoryStorageBackend(initialData: remoteBytes)

        let service = VaultMigrationService(fileStore: fileStore)
        let outcome = try service.migrate(local: local, password: password, remote: remote, strategy: .adoptRemote)

        XCTAssertTrue(outcome.localReplaced)
        XCTAssertFalse(outcome.remoteWritten)
        XCTAssertEqual(
            Set(try XCTUnwrap(outcome.mergedDatabase).rootGroup.entries.map { $0.title }),
            ["Remote Only"]
        )
        XCTAssertEqual(try titlesOnDisk(password: password), ["Remote Only"])
        XCTAssertEqual(try remote.read(), remoteBytes)

        let backups = backupFileURLs
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first)), localBytesBefore)
    }

    func testAdoptRemoteWithWrongPasswordLeavesBothSidesByteIdentical() throws {
        let local = makeDatabase(rootUUID: UUID(), entryTitles: ["Local Only"])
        try fileStore.save(data: try local.save(password: password, cipher: .aes256, compression: .gzip))
        let localBytesBefore = try XCTUnwrap(try fileStore.load())
        let remoteDatabase = makeDatabase(rootUUID: UUID(), entryTitles: ["Remote Only"])
        let remoteBytesBefore = try remoteDatabase.save(
            password: "a-totally-different-password", cipher: .aes256, compression: .gzip
        )
        let remote = InMemoryStorageBackend(initialData: remoteBytesBefore)

        let service = VaultMigrationService(fileStore: fileStore)
        XCTAssertThrowsError(
            try service.migrate(local: local, password: password, remote: remote, strategy: .adoptRemote)
        ) { error in
            guard case VaultMigrationError.remotePasswordMismatch = error else {
                return XCTFail("expected remotePasswordMismatch, got \(error)")
            }
        }
        XCTAssertEqual(try fileStore.load(), localBytesBefore)
        XCTAssertEqual(try remote.read(), remoteBytesBefore)
        XCTAssertTrue(backupFileURLs.isEmpty)
    }

    func testAdoptRemoteRejectsBytesThatAreNotAVault() throws {
        let local = makeDatabase(rootUUID: UUID(), entryTitles: ["Local Only"])
        try fileStore.save(data: try local.save(password: password, cipher: .aes256, compression: .gzip))
        let localBytesBefore = try XCTUnwrap(try fileStore.load())
        let remote = InMemoryStorageBackend(initialData: Data("this is definitely not a kdbx file".utf8))

        let service = VaultMigrationService(fileStore: fileStore)
        XCTAssertThrowsError(
            try service.migrate(local: local, password: password, remote: remote, strategy: .adoptRemote)
        ) { error in
            guard case VaultMigrationError.remoteNotAValidVault = error else {
                return XCTFail("expected remoteNotAValidVault, got \(error)")
            }
        }
        XCTAssertEqual(try fileStore.load(), localBytesBefore)
        XCTAssertTrue(backupFileURLs.isEmpty)
    }

    // MARK: - overwriteRemote

    func testOverwriteRemoteDiscardsRemoteContent() throws {
        let local = makeDatabase(rootUUID: UUID(), entryTitles: ["Local Only"])
        try fileStore.save(data: try local.save(password: password, cipher: .aes256, compression: .gzip))
        let localBytesBefore = try XCTUnwrap(try fileStore.load())
        let remoteDatabase = makeDatabase(rootUUID: UUID(), entryTitles: ["Remote Only"])
        let remote = InMemoryStorageBackend(
            initialData: try remoteDatabase.save(password: password, cipher: .aes256, compression: .gzip)
        )

        let service = VaultMigrationService(fileStore: fileStore)
        let outcome = try service.migrate(local: local, password: password, remote: remote, strategy: .overwriteRemote)

        XCTAssertTrue(outcome.remoteWritten)
        XCTAssertFalse(outcome.localReplaced)
        XCTAssertEqual(try titles(inRemote: remote, password: password), ["Local Only"])
        XCTAssertEqual(try fileStore.load(), localBytesBefore)
    }

    // MARK: - Signature helper

    func testLooksLikeKdbxAcceptsSerializedVaultAndRejectsGarbage() throws {
        let data = try makeDatabase(rootUUID: UUID(), entryTitles: ["Local Only"])
            .save(password: password, cipher: .aes256, compression: .gzip)
        XCTAssertTrue(VaultMigrationService.looksLikeKdbx(data))
        XCTAssertFalse(VaultMigrationService.looksLikeKdbx(Data("nope".utf8)))
        XCTAssertFalse(VaultMigrationService.looksLikeKdbx(Data()))
    }
}
