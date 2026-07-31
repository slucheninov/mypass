import XCTest
import MyPassKit
@testable import MyPass

final class VaultLocationMoveSupportTests: XCTestCase {
    let password = "correct-horse"
    var sourceDir: URL!
    var destDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultLocationMoveSupportTests-\(UUID().uuidString)")
        sourceDir = base.appendingPathComponent("source")
        destDir = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sourceDir.deletingLastPathComponent())
    }

    private func makeDatabase() throws -> KdbxDatabase {
        let now = Date()
        let root = KdbxGroup(
            uuid: UUID(), name: "MyPass", iconID: 0,
            creationTime: now, lastModificationTime: now, locationChanged: now,
            entries: [], subgroups: []
        )
        return KdbxDatabase(rootGroup: root, deletedObjects: [])
    }

    func testVerifyDestinationOpensAcceptsValidKdbxBytes() throws {
        let db = try makeDatabase()
        let data = try db.save(password: password, cipher: .aes256, compression: .gzip)
        XCTAssertNoThrow(try VaultLocationMoveSupport.verifyDestinationOpens(data: data, password: password))
    }

    func testVerifyDestinationOpensRejectsWrongPassword() throws {
        let db = try makeDatabase()
        let data = try db.save(password: password, cipher: .aes256, compression: .gzip)
        XCTAssertThrowsError(try VaultLocationMoveSupport.verifyDestinationOpens(data: data, password: "wrong"))
    }

    func testDeleteSourceVaultRemovesApplicationSupportFile() throws {
        let sourceStore = VaultFileStore(directory: sourceDir)
        let db = try makeDatabase()
        try sourceStore.save(data: try db.save(password: password, cipher: .aes256, compression: .gzip))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceStore.vaultURL.path))

        let deleted = try VaultLocationMoveSupport.deleteSourceVault(at: sourceStore)
        XCTAssertTrue(deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceStore.vaultURL.path))
    }

    func testMoveFlowAfterSeedRemoteLeavesSourceAbsent() throws {
        let sourceStore = VaultFileStore(directory: sourceDir)
        let destStore = VaultFileStore(directory: destDir)
        let db = try makeDatabase()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: Date(), lastModificationTime: Date(),
            lastAccessTime: Date(), locationChanged: Date(), history: []
        )
        entry.title = "Only Entry"
        db.rootGroup.entries.append(entry)
        try sourceStore.save(data: try db.save(password: password, cipher: .aes256, compression: .gzip))

        let service = VaultMigrationService(fileStore: sourceStore)
        _ = try service.migrate(local: db, password: password, remote: destStore, strategy: .seedRemote)

        let destData = try XCTUnwrap(try destStore.load())
        try VaultLocationMoveSupport.verifyDestinationOpens(data: destData, password: password)
        _ = try VaultLocationMoveSupport.deleteSourceVault(at: sourceStore)

        XCTAssertNil(try sourceStore.load())
        XCTAssertNotNil(try destStore.load())
    }

    /// Covers the non-`.seedRemote` case: `.adoptRemote` writes the remote's
    /// existing content into the SOURCE store (not the destination — see
    /// `VaultMigrationService.adoptRemote`), so after migrate the source and
    /// destination hold byte-identical content and it's still correct for
    /// the move flow to verify the destination, then delete the source.
    func testMoveFlowAfterAdoptRemoteLeavesSourceAbsent() throws {
        let sourceStore = VaultFileStore(directory: sourceDir)
        let destStore = VaultFileStore(directory: destDir)

        let localDB = try makeDatabase()
        var localEntry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: Date(), lastModificationTime: Date(),
            lastAccessTime: Date(), locationChanged: Date(), history: []
        )
        localEntry.title = "Local Entry"
        localDB.rootGroup.entries.append(localEntry)
        try sourceStore.save(data: try localDB.save(password: password, cipher: .aes256, compression: .gzip))

        let remoteDB = try makeDatabase()
        var remoteEntry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: Date(), lastModificationTime: Date(),
            lastAccessTime: Date(), locationChanged: Date(), history: []
        )
        remoteEntry.title = "Remote Entry"
        remoteDB.rootGroup.entries.append(remoteEntry)
        try destStore.save(data: try remoteDB.save(password: password, cipher: .aes256, compression: .gzip))

        let service = VaultMigrationService(fileStore: sourceStore)
        let outcome = try service.migrate(local: localDB, password: password, remote: destStore, strategy: .adoptRemote)
        XCTAssertEqual(outcome.strategy, .adoptRemote)
        XCTAssertTrue(outcome.localReplaced)
        XCTAssertFalse(outcome.remoteWritten)

        let destData = try XCTUnwrap(try destStore.load())
        try VaultLocationMoveSupport.verifyDestinationOpens(data: destData, password: password)
        _ = try VaultLocationMoveSupport.deleteSourceVault(at: sourceStore)

        XCTAssertNil(try sourceStore.load())
        let remainingDestData = try XCTUnwrap(try destStore.load())
        let remainingDestDB = try KdbxDatabase.open(data: remainingDestData, password: password)
        XCTAssertEqual(remainingDestDB.rootGroup.entries.first?.title, "Remote Entry")
    }
}
