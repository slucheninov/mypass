import XCTest
import MyPassKit
import SyncKit
@testable import MyPass

final class VaultSessionTests: XCTestCase {
    var tempDir: URL!
    var fileStore: VaultFileStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPassVaultSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileStore = VaultFileStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testUnlockWithNoExistingVaultCreatesEmptyDatabase() throws {
        let session = VaultSession(fileStore: fileStore)
        XCTAssertEqual(session.state, .locked)
        try session.unlock(password: "correct-horse")
        guard case .unlocked(let db) = session.state else {
            return XCTFail("expected unlocked state")
        }
        XCTAssertEqual(db.rootGroup.name, "MyPass")
        XCTAssertEqual(db.rootGroup.entries.count, 0)
    }

    func testUnlockWithWrongPasswordThrowsAndStaysLocked() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")
        session.lock()

        let secondSession = VaultSession(fileStore: fileStore)
        XCTAssertThrowsError(try secondSession.unlock(password: "wrong-password")) { error in
            XCTAssertEqual(error as? KdbxDatabaseError, .wrongPassword)
        }
        XCTAssertEqual(secondSession.state, .locked)
    }

    func testMutateAutosavesSoASecondSessionSeesTheChange() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")

        let dataBeforeMutation = try fileStore.load()

        let now = Date()
        let entry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: now,
            lastModificationTime: now,
            lastAccessTime: now,
            locationChanged: now,
            history: []
        )
        session.mutate { database in
            var mutableEntry = entry
            mutableEntry.title = "Mutated Entry"
            database.rootGroup.entries.append(mutableEntry)
        }

        var dataAfterMutation: Data?
        for _ in 0..<30 {
            let candidate = try fileStore.load()
            if candidate != dataBeforeMutation {
                dataAfterMutation = candidate
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertNotNil(dataAfterMutation, "expected the autosave to write new data to disk within the timeout")
        XCTAssertNil(session.lastSaveError)

        let secondSession = VaultSession(fileStore: fileStore)
        try secondSession.unlock(password: "correct-horse")
        guard case .unlocked(let db) = secondSession.state else {
            return XCTFail("expected unlocked state")
        }
        XCTAssertEqual(db.rootGroup.entries.count, 1)
        XCTAssertEqual(db.rootGroup.entries.first?.title, "Mutated Entry")
    }

    func testRapidBackToBackMutationsBothPersistWithoutCorruption() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")

        func makeEntry(title: String) -> KdbxEntry {
            let now = Date()
            var entry = KdbxEntry(
                uuid: UUID(),
                iconID: 0,
                fields: [],
                creationTime: now,
                lastModificationTime: now,
                lastAccessTime: now,
                locationChanged: now,
                history: []
            )
            entry.title = title
            return entry
        }

        session.mutate { database in
            database.rootGroup.entries.append(makeEntry(title: "First Entry"))
        }
        session.mutate { database in
            database.rootGroup.entries.append(makeEntry(title: "Second Entry"))
        }

        guard case .unlocked(let inMemoryDb) = session.state else {
            return XCTFail("expected unlocked state")
        }
        XCTAssertEqual(inMemoryDb.rootGroup.entries.count, 2)

        var sawBothEntries = false
        for _ in 0..<100 {
            if let data = try fileStore.load(),
               let db = try? KdbxDatabase.open(data: data, password: "correct-horse"),
               db.rootGroup.entries.count == 2 {
                let titles = Set(db.rootGroup.entries.map { $0.title })
                if titles == ["First Entry", "Second Entry"] {
                    sawBothEntries = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(sawBothEntries, "expected both rapid mutations to be reflected on disk within the timeout")
        XCTAssertNil(session.lastSaveError)
    }

    func testUnlockWithSyncEngineAppliesMergedResult() throws {
        let bootstrapSession = VaultSession(fileStore: fileStore)
        try bootstrapSession.unlock(password: "correct-horse")
        guard case .unlocked(let bootstrapDb) = bootstrapSession.state else {
            return XCTFail("expected unlocked state")
        }
        let rootUUID = bootstrapDb.rootGroup.uuid

        let remote = InMemoryStorageBackend()
        var remoteEntry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: Date(timeIntervalSince1970: 10_000),
            lastModificationTime: Date(timeIntervalSince1970: 10_000),
            lastAccessTime: Date(timeIntervalSince1970: 10_000),
            locationChanged: Date(timeIntervalSince1970: 10_000),
            history: []
        )
        remoteEntry.title = "From Remote"
        let remoteRoot = KdbxGroup(
            uuid: rootUUID,
            name: "MyPass",
            iconID: 0,
            creationTime: Date(timeIntervalSince1970: 10_000),
            lastModificationTime: Date(timeIntervalSince1970: 10_000),
            locationChanged: Date(timeIntervalSince1970: 10_000),
            entries: [remoteEntry],
            subgroups: []
        )
        let remoteDatabase = KdbxDatabase(rootGroup: remoteRoot, deletedObjects: [])
        try remote.write(try remoteDatabase.save(password: "correct-horse", cipher: .aes256, compression: .gzip))

        let syncEngine = SyncEngine(remote: remote, checkpointStore: InMemorySyncCheckpointStore())
        let syncedSession = VaultSession(fileStore: fileStore, syncEngine: syncEngine)
        try syncedSession.unlock(password: "correct-horse")

        guard case .unlocked(let mergedDb) = syncedSession.state else {
            return XCTFail("expected unlocked state")
        }
        XCTAssertTrue(mergedDb.rootGroup.entries.contains { $0.title == "From Remote" })
        XCTAssertNil(syncedSession.lastSaveError)

        let verifyingSession = VaultSession(fileStore: fileStore)
        try verifyingSession.unlock(password: "correct-horse")
        guard case .unlocked(let dbOnDisk) = verifyingSession.state else {
            return XCTFail("expected unlocked state")
        }
        XCTAssertTrue(dbOnDisk.rootGroup.entries.contains { $0.title == "From Remote" })
    }

    func testPersistWithSyncEngineAlsoSyncsRemote() throws {
        let remote = InMemoryStorageBackend()
        let syncEngine = SyncEngine(remote: remote, checkpointStore: InMemorySyncCheckpointStore())
        let session = VaultSession(fileStore: fileStore, syncEngine: syncEngine)
        try session.unlock(password: "correct-horse")

        let remoteDataBeforeMutation = try remote.read()

        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: now,
            lastModificationTime: now,
            lastAccessTime: now,
            locationChanged: now,
            history: []
        )
        entry.title = "Synced Entry"
        session.mutate { database in
            database.rootGroup.entries.append(entry)
        }

        var sawEntryOnRemote = false
        for _ in 0..<100 {
            if let data = try remote.read(),
               data != remoteDataBeforeMutation,
               let db = try? KdbxDatabase.open(data: data, password: "correct-horse"),
               db.rootGroup.entries.contains(where: { $0.title == "Synced Entry" }) {
                sawEntryOnRemote = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(sawEntryOnRemote, "expected persist()'s background sync leg to upload the mutation to remote within the timeout")
        XCTAssertNil(session.lastSaveError)
    }

    func testPersistSyncFailureSurfacesLastSaveError() throws {
        let remote = InMemoryStorageBackend()
        let syncEngine = SyncEngine(remote: remote, checkpointStore: InMemorySyncCheckpointStore())
        let session = VaultSession(fileStore: fileStore, syncEngine: syncEngine)
        try session.unlock(password: "correct-horse")
        XCTAssertNil(session.lastSaveError)

        struct SimulatedRemoteFailure: Error {}
        remote.writeError = SimulatedRemoteFailure()

        let dataBeforeMutation = try fileStore.load()
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: now,
            lastModificationTime: now,
            lastAccessTime: now,
            locationChanged: now,
            history: []
        )
        entry.title = "Local Only Despite Sync Failure"
        session.mutate { database in
            database.rootGroup.entries.append(entry)
        }

        var dataAfterMutation: Data?
        for _ in 0..<30 {
            let candidate = try fileStore.load()
            if candidate != dataBeforeMutation {
                dataAfterMutation = candidate
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertNotNil(dataAfterMutation, "expected the local autosave to succeed even when remote sync fails")

        var sawSyncError = false
        for _ in 0..<100 {
            if let message = session.lastSaveError, message.localizedCaseInsensitiveContains("sync") {
                sawSyncError = true
                break
            }
            // `lastSaveError` is set via `DispatchQueue.main.async`, so waiting
            // must pump the main run loop rather than block it with Thread.sleep.
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(sawSyncError, "expected lastSaveError to surface a sync-specific failure message within the timeout")
    }
}
