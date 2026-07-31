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

    // MARK: - Migration

    private func makeMigrationEntry(title: String) -> KdbxEntry {
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

    func testPerformMigrationIsRejectedWhileLocked() {
        let session = VaultSession(fileStore: fileStore)
        let expectation = expectation(description: "completion")

        session.performMigration(to: InMemoryStorageBackend(), strategy: .seedRemote) { result in
            switch result {
            case .success:
                XCTFail("expected failure while locked")
            case .failure(let error):
                guard case VaultMigrationError.vaultLocked = error else {
                    return XCTFail("expected vaultLocked, got \(error)")
                }
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    func testProbeMigrationTargetIsRejectedWhileLocked() {
        let session = VaultSession(fileStore: fileStore)
        let expectation = expectation(description: "completion")

        session.probeMigrationTarget(remote: InMemoryStorageBackend()) { result in
            switch result {
            case .success:
                XCTFail("expected failure while locked")
            case .failure(let error):
                guard case VaultMigrationError.vaultLocked = error else {
                    return XCTFail("expected vaultLocked, got \(error)")
                }
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    func testPerformMigrationCancelsPendingTouchAccessPersist() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")

        let entry = makeMigrationEntry(title: "Touched Entry")
        session.mutate { database in
            database.rootGroup.entries.append(entry)
        }
        session.touchAccess(entryID: entry.uuid)
        XCTAssertTrue(session.hasPendingTouchAccessPersist)

        let expectation = expectation(description: "completion")
        session.performMigration(to: InMemoryStorageBackend(), strategy: .seedRemote) { result in
            if case .failure(let error) = result {
                XCTFail("expected success, got \(error)")
            }
            expectation.fulfill()
        }
        XCTAssertFalse(session.hasPendingTouchAccessPersist)

        wait(for: [expectation], timeout: 30)
    }

    func testPerformMigrationSeedRemoteUploadsWithoutChangingInMemoryState() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")
        session.mutate { database in
            database.rootGroup.entries.append(self.makeMigrationEntry(title: "Local Only"))
        }

        let remote = InMemoryStorageBackend()
        let expectation = expectation(description: "completion")
        session.performMigration(to: remote, strategy: .seedRemote) { result in
            switch result {
            case .success(let outcome):
                XCTAssertTrue(outcome.remoteWritten)
                XCTAssertFalse(outcome.localReplaced)
                XCTAssertNil(outcome.mergedDatabase)
            case .failure(let error):
                XCTFail("expected success, got \(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 60)

        guard case .unlocked(let db) = session.state else {
            return XCTFail("expected unlocked state")
        }
        XCTAssertEqual(Set(db.rootGroup.entries.map { $0.title }), ["Local Only"])

        let remoteData = try XCTUnwrap(try remote.read())
        let remoteDatabase = try KdbxDatabase.open(data: remoteData, password: "correct-horse")
        XCTAssertEqual(Set(remoteDatabase.rootGroup.entries.map { $0.title }), ["Local Only"])
    }

    func testPerformMigrationAdoptRemotePublishesTheAdoptedDatabase() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")
        session.mutate { database in
            database.rootGroup.entries.append(self.makeMigrationEntry(title: "Local Only"))
        }

        var remoteEntry = makeMigrationEntry(title: "From Remote")
        remoteEntry.title = "From Remote"
        let remoteRoot = KdbxGroup(
            uuid: UUID(),
            name: "MyPass",
            iconID: 0,
            creationTime: Date(),
            lastModificationTime: Date(),
            locationChanged: Date(),
            entries: [remoteEntry],
            subgroups: []
        )
        let remoteDatabase = KdbxDatabase(rootGroup: remoteRoot, deletedObjects: [])
        let remote = InMemoryStorageBackend(
            initialData: try remoteDatabase.save(password: "correct-horse", cipher: .aes256, compression: .gzip)
        )

        let expectation = expectation(description: "completion")
        session.performMigration(to: remote, strategy: .adoptRemote) { result in
            switch result {
            case .success(let outcome):
                XCTAssertTrue(outcome.localReplaced)
                XCTAssertFalse(outcome.remoteWritten)
            case .failure(let error):
                XCTFail("expected success, got \(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 60)

        guard case .unlocked(let db) = session.state else {
            return XCTFail("expected unlocked state")
        }
        XCTAssertEqual(Set(db.rootGroup.entries.map { $0.title }), ["From Remote"])
    }

    func testProbeMigrationTargetReportsOccupiedRemote() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")

        let remoteDatabase = KdbxDatabase(
            rootGroup: KdbxGroup(
                uuid: UUID(),
                name: "MyPass",
                iconID: 0,
                creationTime: Date(),
                lastModificationTime: Date(),
                locationChanged: Date(),
                entries: [makeMigrationEntry(title: "From Remote")],
                subgroups: []
            ),
            deletedObjects: []
        )
        let remoteData = try remoteDatabase.save(password: "correct-horse", cipher: .aes256, compression: .gzip)
        let remote = InMemoryStorageBackend(initialData: remoteData)

        let expectation = expectation(description: "completion")
        session.probeMigrationTarget(remote: remote) { result in
            switch result {
            case .success(let probe):
                XCTAssertTrue(probe.exists)
                XCTAssertEqual(probe.byteCount, remoteData.count)
                XCTAssertNotNil(probe.modificationDate)
            case .failure(let error):
                XCTFail("expected success, got \(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 30)
    }

    func testPerformMigrationDoesNotReLockIfLockedDuringFlight() throws {
        // Create a remote database that adoptRemote will read
        let remoteEntry = makeMigrationEntry(title: "From Remote")
        let remoteRoot = KdbxGroup(
            uuid: UUID(),
            name: "MyPass",
            iconID: 0,
            creationTime: Date(),
            lastModificationTime: Date(),
            locationChanged: Date(),
            entries: [remoteEntry],
            subgroups: []
        )
        let remoteDatabase = KdbxDatabase(rootGroup: remoteRoot, deletedObjects: [])
        let remoteData = try remoteDatabase.save(password: "correct-horse", cipher: .aes256, compression: .gzip)

        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")
        session.mutate { database in
            database.rootGroup.entries.append(self.makeMigrationEntry(title: "Local Only"))
        }

        // Use a blocking backend that blocks on read() with valid KDBX data
        let blockingBackend = BlockingStorageBackend(data: remoteData)

        let expectation = expectation(description: "completion")
        session.performMigration(to: blockingBackend, strategy: .adoptRemote) { result in
            if case .failure(let error) = result {
                XCTFail("expected success, got \(error)")
            }
            expectation.fulfill()
        }

        // Wait until the backend's read() is blocked
        blockingBackend.waitForBlockedRead()

        // Lock the vault while the migration is in flight
        session.lock()
        XCTAssertEqual(session.state, .locked)

        // Unblock the backend to let the migration complete
        blockingBackend.unblockRead()

        // Wait for the migration to complete
        wait(for: [expectation], timeout: 30)

        // Verify the vault is still locked, not silently re-unlocked by the guarded code
        XCTAssertEqual(session.state, .locked)
    }

    // MARK: - verifyPassword / updatePrimaryStore

    func testVerifyPasswordReturnsTrueForCorrectPasswordWithoutMutatingState() throws {
        let session = VaultSession(fileStore: VaultFileStore(directory: tempDir))
        try session.unlock(password: "correct-horse")
        session.lock()

        XCTAssertTrue(session.verifyPassword("correct-horse"))
        XCTAssertEqual(session.state, .locked)
    }

    func testVerifyPasswordReturnsFalseForWrongPassword() throws {
        let session = VaultSession(fileStore: VaultFileStore(directory: tempDir))
        try session.unlock(password: "correct-horse")
        session.lock()

        XCTAssertFalse(session.verifyPassword("wrong-password"))
    }

    func testVerifyPasswordReturnsFalseWhenNoVaultExistsYet() {
        let session = VaultSession(fileStore: VaultFileStore(directory: tempDir))
        XCTAssertFalse(session.verifyPassword("anything"))
    }

    func testUpdatePrimaryStoreSwapsWhereSubsequentUnlockReadsFrom() throws {
        let firstDir = tempDir.appendingPathComponent("first")
        let secondDir = tempDir.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)

        let session = VaultSession(fileStore: VaultFileStore(directory: firstDir))
        try session.unlock(password: "pw") // creates a fresh vault under firstDir
        session.lock()

        session.updatePrimaryStore(VaultFileStore(directory: secondDir))

        // secondDir has no vault yet, so unlocking now creates a brand new one there.
        XCTAssertNil(try session.loadVaultData())
        try session.unlock(password: "different-pw")
        XCTAssertNotNil(session.currentDatabase)
    }

    func testUpdatePrimaryStoreRewiresOnRemoteChangeForTheNewStore() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")

        let icloudFolder = tempDir.appendingPathComponent("icloud-folder")
        let icloudBackups = tempDir.appendingPathComponent("icloud-backups")
        try FileManager.default.createDirectory(at: icloudFolder, withIntermediateDirectories: true)
        let bookmark = try iCloudBackend.createFolderBookmark(for: icloudFolder)
        let iCloudStore = try ICloudDriveVaultStore(bookmarkData: bookmark, localBackupDirectory: icloudBackups)

        session.updatePrimaryStore(iCloudStore)

        XCTAssertNotNil(
            iCloudStore.onRemoteChange,
            "expected updatePrimaryStore to wire onRemoteChange on the swapped-in store, not just the one built at launch"
        )

        // Simulate an external change notification on the *new* store and
        // confirm it actually reaches VaultSession's background sync path
        // (a persist to that same store), not just that a closure is set.
        iCloudStore.onRemoteChange?()

        var sawWrite = false
        for _ in 0..<30 {
            if (try? iCloudStore.load()) != nil {
                sawWrite = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(sawWrite, "expected the rewired onRemoteChange handler to trigger a background sync that persists to the new store")
    }

    func testPrimaryVaultPathDisplayReturnsVaultURLPath() throws {
        let session = VaultSession(fileStore: fileStore)
        XCTAssertEqual(session.primaryVaultPathDisplay, fileStore.primaryVaultFileURL?.path)
    }

    func testPrimaryVaultPathDisplayUnavailableWhenURLNil() {
        final class NoURLStore: VaultPrimaryStorage {
            var primaryVaultFileURL: URL? { nil }
            func load() throws -> Data? { nil }
            func save(data: Data) throws {}
            func deleteVaultFileIfPresent() throws {}
        }
        let session = VaultSession(fileStore: NoURLStore())
        XCTAssertEqual(session.primaryVaultPathDisplay, "Path unavailable")
    }

    // MARK: - Skip-identical-bytes persist

    func testPersistSkipsWriteWhenSerializedBytesUnchanged() throws {
        let spy = CountingVaultPrimaryStorage(inner: fileStore)
        let session = VaultSession(fileStore: spy)
        try session.unlock(password: "correct-horse")
        waitForPersist(on: session)

        // Establish a real, non-empty write first — `hasDirtyLocalChanges` is
        // only set by `mutate`, so calling `triggerBackgroundSyncIfDirty()`
        // right after `unlock()` alone would return before `persist(_:)` is
        // even invoked and never reach the skip branch under test.
        session.mutate { db in
            var entry = KdbxEntry(
                uuid: UUID(), iconID: 0, fields: [],
                creationTime: Date(), lastModificationTime: Date(),
                lastAccessTime: Date(), locationChanged: Date(), history: []
            )
            entry.title = "New"
            db.rootGroup.entries.append(entry)
        }
        waitForPersist(on: session)
        let writesAfterRealMutation = spy.saveCallCount
        XCTAssertGreaterThan(writesAfterRealMutation, 0)

        // `KdbxDatabase.save(password:cipher:compression:)` mints fresh
        // random KDF salt/IV/inner-stream-key material via SecRandomCopyBytes
        // on every call, so two serializations of logically identical
        // content are essentially never byte-identical — a raw ciphertext
        // comparison would never hit the skip branch. This no-op `mutate`
        // re-triggers `persist(_:)` with a database that has the same
        // entries/tree as what's already on disk; the skip check must be
        // based on that logical content, not the (always-different) bytes.
        session.mutate { _ in }
        waitForBackgroundWork()

        XCTAssertEqual(
            spy.saveCallCount, writesAfterRealMutation,
            "logically identical content should not invoke save again, even though re-serializing it produces different ciphertext bytes"
        )

        // The skip path also clears `hasDirtyLocalChanges`, so a follow-up
        // timer tick should likewise be a no-op — confirms the dirty flag and
        // the logical-equality skip check agree rather than fighting.
        session.triggerBackgroundSyncIfDirty()
        waitForBackgroundWork()
        XCTAssertEqual(
            spy.saveCallCount, writesAfterRealMutation,
            "no pending changes after a skipped persist should mean no further writes"
        )
    }

    func testPersistWritesWhenDatabaseMutated() throws {
        let spy = CountingVaultPrimaryStorage(inner: fileStore)
        let session = VaultSession(fileStore: spy)
        try session.unlock(password: "correct-horse")
        waitForPersist(on: session)
        let baseline = spy.saveCallCount

        session.mutate { db in
            var entry = KdbxEntry(
                uuid: UUID(), iconID: 0, fields: [],
                creationTime: Date(), lastModificationTime: Date(),
                lastAccessTime: Date(), locationChanged: Date(), history: []
            )
            entry.title = "New"
            db.rootGroup.entries.append(entry)
        }
        waitForPersist(on: session)
        XCTAssertGreaterThan(spy.saveCallCount, baseline)
    }

    private func waitForPersist(on session: VaultSession, file: StaticString = #file, line: UInt = #line) {
        for _ in 0..<50 {
            if session.lastSaveError != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func waitForBackgroundWork() {
        Thread.sleep(forTimeInterval: 0.3)
    }
}

// MARK: - Test Doubles

/// A storage backend that blocks on read() until explicitly unblocked,
/// used to reliably trigger the race condition between lock() and migration completion.
/// Returns valid KDBX bytes so adoptRemote can parse and open the remote database.
private class BlockingStorageBackend: StorageBackend {
    private let data: Data
    private let readBlocker = DispatchSemaphore(value: 0)
    private let readBlocked = DispatchSemaphore(value: 0)

    init(data: Data) {
        self.data = data
    }

    func read() throws -> Data? {
        // Signal that we're now blocked
        readBlocked.signal()
        // Wait for the unblock signal
        _ = readBlocker.wait(timeout: .now() + 10)
        return data
    }

    func write(_ data: Data) throws {
        // No-op for this test
    }

    func modificationDate() throws -> Date? {
        Date()
    }

    func exists() throws -> Bool {
        true
    }

    func waitForBlockedRead() {
        // Wait for read() to signal that it's blocked
        let result = readBlocked.wait(timeout: .now() + 10)
        if result == .timedOut {
            XCTFail("read() never blocked within timeout")
        }
    }

    func unblockRead() {
        readBlocker.signal()
    }
}

/// Wraps a `VaultFileStore` and counts `save(data:)` invocations, so tests can
/// assert that identical-bytes persists are skipped rather than re-written.
private final class CountingVaultPrimaryStorage: VaultPrimaryStorage {
    let inner: VaultFileStore
    private(set) var saveCallCount = 0

    init(inner: VaultFileStore) { self.inner = inner }

    var primaryVaultFileURL: URL? { inner.primaryVaultFileURL }
    func load() throws -> Data? { try inner.load() }
    func deleteVaultFileIfPresent() throws { try inner.deleteVaultFileIfPresent() }

    func save(data: Data) throws {
        saveCallCount += 1
        try inner.save(data: data)
    }
}
