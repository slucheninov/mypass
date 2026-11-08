import XCTest
import MyPassKit
import SyncKit
@testable import MyPass

/// Isolated `UserDefaults` so backup tests never read or write the developer's real settings.
enum BackupTestDefaults {
    private static var suites: [String] = []
    private static let lock = NSLock()

    /// Removes every suite created since the last call; call from `tearDown`.
    static func cleanUp() {
        lock.lock(); let names = suites; suites = []; lock.unlock()
        names.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
    }

    static func make(count: Int? = nil, interval: VaultBackupInterval? = nil) -> UserDefaults {
        let name = "MyPassBackupTests-\(UUID().uuidString)"
        lock.lock(); suites.append(name); lock.unlock()
        let defaults = UserDefaults(suiteName: name)!
        if let count { defaults.set(count, forKey: VaultBackupSettings.countKey) }
        if let interval { defaults.set(interval.rawValue, forKey: VaultBackupSettings.intervalKey) }
        return defaults
    }
}

final class VaultBackupManagerTests: XCTestCase {
    var dir: URL!
    var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("MyPassBackupManagerTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        BackupTestDefaults.cleanUp()
        try? FileManager.default.removeItem(at: dir)
    }

    private func manager(_ defaults: UserDefaults) -> VaultBackupManager {
        VaultBackupManager(directory: dir, defaults: defaults, now: { [unowned self] in self.clock })
    }

    private func snap(_ m: VaultBackupManager, _ text: String) {
        m.snapshotIfDue { Data(text.utf8) }
        clock = clock.addingTimeInterval(1)
    }

    func testCountIsReadLiveAndLoweringPrunesOnNextBackup() {
        let defaults = BackupTestDefaults.make(count: 5)
        let m = manager(defaults)
        for i in 0..<6 { snap(m, "v\(i)") }
        XCTAssertEqual(m.list().count, 5)
        defaults.set(2, forKey: VaultBackupSettings.countKey)
        snap(m, "v6")
        XCTAssertEqual(m.list().count, 2)
        // Newest two survive, newest first.
        let contents = m.list().map { String(data: try! Data(contentsOf: $0.url), encoding: .utf8)! }
        XCTAssertEqual(contents, ["v6", "v5"])
    }

    func testCountIsClamped() {
        let low = BackupTestDefaults.make(count: 0)
        XCTAssertEqual(VaultBackupSettings.count(defaults: low), 1)
        let high = BackupTestDefaults.make(count: 999)
        XCTAssertEqual(VaultBackupSettings.count(defaults: high), 50)
        XCTAssertEqual(VaultBackupSettings.count(defaults: BackupTestDefaults.make()), 10)
    }

    func testIntervalPolicyDecision() {
        let now = Date(timeIntervalSince1970: 100_000)
        func due(_ i: VaultBackupInterval, ago: TimeInterval?, first: Bool = false) -> Bool {
            VaultBackupSettings.isSnapshotDue(
                interval: i, newestBackupDate: ago.map { now.addingTimeInterval(-$0) }, now: now, isFirstWriteOfSession: first)
        }
        XCTAssertTrue(due(.everySave, ago: 1))
        XCTAssertFalse(due(.tenMinutes, ago: 599))
        XCTAssertTrue(due(.tenMinutes, ago: 600))
        XCTAssertFalse(due(.hourly, ago: 3599))
        XCTAssertTrue(due(.hourly, ago: 3600))
        XCTAssertFalse(due(.daily, ago: 86399))
        XCTAssertTrue(due(.daily, ago: 86400))
        XCTAssertTrue(due(.daily, ago: nil))
        XCTAssertTrue(due(.daily, ago: 1, first: true), "first write of a session always snapshots")
    }

    func testManagerAppliesIntervalAndFirstWriteOfSession() {
        let m = manager(BackupTestDefaults.make(interval: .tenMinutes))
        snap(m, "a")                       // first of session: taken
        XCTAssertEqual(m.list().count, 1)
        clock = clock.addingTimeInterval(300)
        snap(m, "b")                       // 5 min later: skipped
        XCTAssertEqual(m.list().count, 1)
        clock = clock.addingTimeInterval(400)
        snap(m, "c")                       // 11+ min since newest: taken
        XCTAssertEqual(m.list().count, 2)
        m.beginSession()
        snap(m, "d")                       // new session: taken even though recent
        XCTAssertEqual(m.list().count, 3)
    }

    func testReadIsSkippedWhenNotDue() {
        let m = manager(BackupTestDefaults.make(interval: .daily))
        snap(m, "a")
        var read = false
        m.snapshotIfDue { read = true; return nil }
        XCTAssertFalse(read)
    }

    func testFailureIsRecordedNotThrownAndClearedOnSuccess() throws {
        let defaults = BackupTestDefaults.make()
        let m = manager(defaults)
        try Data().write(to: dir) // a file where the directory should be
        snap(m, "a")
        XCTAssertNotNil(m.lastFailure)
        XCTAssertFalse(m.lastFailure!.message.isEmpty)
        try FileManager.default.removeItem(at: dir)
        snap(m, "b")
        XCTAssertNil(m.lastFailure)
        XCTAssertEqual(m.list().count, 1)
    }

    func testForceSnapshotIgnoresIntervalAndSuppressionSkipsAutomatic() throws {
        let m = manager(BackupTestDefaults.make(interval: .daily))
        snap(m, "a")
        try m.forceSnapshot(Data("forced".utf8))
        XCTAssertEqual(m.list().count, 2)
        m.beginSession()
        m.withSnapshotsSuppressed { snap(m, "suppressed") }
        XCTAssertEqual(m.list().count, 2)
    }

    // MARK: - Stores: a backup failure never blocks the save and is recorded

    func testVaultFileStoreSaveSucceedsWhenBackupFails() throws {
        let defaults = BackupTestDefaults.make()
        let root = dir!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let backups = root.appendingPathComponent("backups")
        let manager = VaultBackupManager(directory: backups, defaults: defaults)
        let store = VaultFileStore(directory: root, backupManager: manager)
        try store.save(data: Data("one".utf8))
        try Data().write(to: backups)
        XCTAssertNoThrow(try store.save(data: Data("two".utf8)))
        XCTAssertEqual(try store.load(), Data("two".utf8))
        XCTAssertNotNil(manager.lastFailure)
    }

    func testLocalFileStoreRecordsBackupFailureWithoutBlockingSave() throws {
        let defaults = BackupTestDefaults.make()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("v.kdbx")
        try Data("seed".utf8).write(to: file)
        let backups = dir.appendingPathComponent("backups")
        try Data().write(to: backups)
        let manager = VaultBackupManager(directory: backups, defaults: defaults)
        let store = try LocalFileVaultStore(
            bookmarkData: LocalFileVaultStore.createFileBookmark(for: file),
            localBackupDirectory: backups,
            backupManager: manager)
        XCTAssertNoThrow(try store.save(data: Data("next".utf8)))
        XCTAssertEqual(try Data(contentsOf: file), Data("next".utf8))
        XCTAssertNotNil(manager.lastFailure)
    }

    func testNegativeElapsedCountsAsDue() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertTrue(VaultBackupSettings.isSnapshotDue(
            interval: .daily, newestBackupDate: now.addingTimeInterval(3600), now: now, isFirstWriteOfSession: false))
    }

    func testPruneFailureAfterSuccessfulSnapshotDoesNotFailForceSnapshot() throws {
        struct Boom: Error {}
        let defaults = BackupTestDefaults.make(count: 1)
        let m = VaultBackupManager(directory: dir, defaults: defaults, now: { [unowned self] in self.clock },
                                   removeFile: { _ in throw Boom() })
        snap(m, "a")
        XCTAssertNoThrow(try m.forceSnapshot(Data("b".utf8)))
        m.pruneNow()
        XCTAssertNil(m.lastFailure)
        XCTAssertEqual(m.list().count, 2, "prune failed but both snapshots are on disk")
    }

    func testPruneNeverDeletesTheSnapshotJustWrittenWhenAnOlderOneIsFutureDated() throws {
        let m = manager(BackupTestDefaults.make(count: 1))
        clock = clock.addingTimeInterval(10_000)
        snap(m, "future")                     // dated ahead of the clock used below
        clock = Date(timeIntervalSince1970: 1_000_000)
        snap(m, "fresh")
        let kept = m.list().map { String(data: try! Data(contentsOf: $0.url), encoding: .utf8)! }
        XCTAssertEqual(kept, ["fresh"])
    }

    func testPruneNowProtectsTheGivenSnapshot() throws {
        let m = manager(BackupTestDefaults.make(count: 1))
        clock = clock.addingTimeInterval(10_000)
        snap(m, "future")
        clock = Date(timeIntervalSince1970: 1_000_000)
        let url = try m.forceSnapshot(Data("safety".utf8))
        m.pruneNow(protecting: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(m.list().count, 1)
    }

    func testForceSnapshotDoesNotPruneUntilPruneNow() throws {
        let m = manager(BackupTestDefaults.make(count: 1))
        snap(m, "oldest")
        try m.forceSnapshot(Data("forced".utf8))
        XCTAssertEqual(m.list().count, 2)
        m.pruneNow()
        let kept = m.list().map { String(data: try! Data(contentsOf: $0.url), encoding: .utf8)! }
        XCTAssertEqual(kept, ["forced"])
    }

    // MARK: - Session restore

    private func makeVaultPair() throws -> (backupFile: URL, oldBytes: Data, currentBytes: Data, defaults: UserDefaults) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaults = BackupTestDefaults.make(count: 1)
        let store = VaultFileStore(directory: dir, backupManager: VaultBackupManager(directory: dir.appendingPathComponent("backups"), defaults: defaults))
        let first = VaultSession(fileStore: store)
        try first.unlock(password: "old-password")
        let oldBytes = try Data(contentsOf: dir.appendingPathComponent("vault.kdbx"))
        let backupFile = dir.appendingPathComponent("chosen.kdbx")
        try oldBytes.write(to: backupFile)
        first.lock()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("vault.kdbx"))
        let second = VaultSession(fileStore: store)
        try second.unlock(password: "new-password")
        second.lock()
        return (backupFile, oldBytes, try Data(contentsOf: dir.appendingPathComponent("vault.kdbx")), defaults)
    }

    func testRestoreOfOldestBackupAtLimitKeepsSourceWhenWriteFails() throws {
        let pair = try makeVaultPair()
        let backups = dir.appendingPathComponent("backups")
        let manager = VaultBackupManager(directory: backups, defaults: pair.defaults)
        // The single allowed backup is the restore source.
        let source = backups.appendingPathComponent("vault-1.000000.kdbx")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try pair.oldBytes.write(to: source)
        let store = ControllableVaultStore(directory: dir, manager: manager)
        store.failWrites(with: NSError(domain: "test", code: 1))
        let session = VaultSession(fileStore: store)
        XCTAssertThrowsError(try session.restoreBackup(from: source, defaults: pair.defaults))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "restore source must survive a failed write")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("vault.kdbx")), pair.currentBytes)
    }

    func testSuccessfulRestoreAtLimitPrunesAfterwardsKeepingNewest() throws {
        let pair = try makeVaultPair()
        let session = VaultSession(fileStore: VaultFileStore(
            directory: dir,
            backupManager: VaultBackupManager(directory: dir.appendingPathComponent("backups"), defaults: pair.defaults)))
        try session.restoreBackup(from: pair.backupFile, defaults: pair.defaults)
        let kept = try session.backupManager!.list().map { try Data(contentsOf: $0.url) }
        XCTAssertEqual(kept, [pair.currentBytes], "count 1: only the newest (pre-restore) snapshot remains")
    }

    func testRestoreClearsSyncCheckpoints() throws {
        let pair = try makeVaultPair()
        let key = SyncBackendResolver.checkpointKey(for: .folder)
        pair.defaults.set(Date(), forKey: key)
        let session = VaultSession(fileStore: VaultFileStore(
            directory: dir,
            backupManager: VaultBackupManager(directory: dir.appendingPathComponent("backups"), defaults: pair.defaults)))
        try session.restoreBackup(from: pair.backupFile, defaults: pair.defaults)
        XCTAssertNil(pair.defaults.object(forKey: key))
    }

    func testRestoreAbortsWhenSafetySnapshotFails() throws {
        let pair = try makeVaultPair()
        let backups = dir.appendingPathComponent("backups")
        try? FileManager.default.removeItem(at: backups)
        try Data().write(to: backups) // snapshot cannot be written
        let session = VaultSession(fileStore: VaultFileStore(
            directory: dir, backupManager: VaultBackupManager(directory: backups, defaults: pair.defaults)))
        XCTAssertThrowsError(try session.restoreBackup(from: pair.backupFile, defaults: pair.defaults))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("vault.kdbx")), pair.currentBytes)
    }

    /// Blocks `write` (the sync's upload) until released, to hold a sync in flight.
    final class BlockingRemote: StorageBackend {
        let inner = InMemoryStorageBackend()
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var blocking = false
        func block() { lock.lock(); blocking = true; lock.unlock() }
        func read() throws -> Data? { try inner.read() }
        func exists() throws -> Bool { try inner.exists() }
        func modificationDate() throws -> Date? { try inner.modificationDate() }
        func write(_ data: Data) throws {
            lock.lock(); let b = blocking; lock.unlock()
            if b { entered.signal(); gate.wait() }
            try inner.write(data)
        }
    }

    func testRestoreRefusedWhileSyncIsInFlightThenAllowed() throws {
        let pair = try makeVaultPair()
        let remote = BlockingRemote()
        let engine = SyncEngine(remote: remote, checkpointStore: InMemorySyncCheckpointStore())
        let store = VaultFileStore(
            directory: dir,
            backupManager: VaultBackupManager(directory: dir.appendingPathComponent("backups"), defaults: pair.defaults))
        let session = VaultSession(fileStore: store, syncEngine: engine)
        try session.unlock(password: "new-password")
        remote.block()
        session.mutate { $0.rootGroup.name = "changed" }
        XCTAssertEqual(remote.entered.wait(timeout: .now() + 30), .success, "sync never started")
        // The local write is finished; only the remote sync is still running.
        XCTAssertThrowsError(try session.restoreBackup(from: pair.backupFile, defaults: pair.defaults)) {
            XCTAssertEqual($0 as? VaultSessionError, .writeInProgress)
        }
        remote.gate.signal()
        let deadline = Date().addingTimeInterval(30)
        var restored = false
        while Date() < deadline, !restored {
            do { try session.restoreBackup(from: pair.backupFile, defaults: pair.defaults); restored = true }
            catch { Thread.sleep(forTimeInterval: 0.05) }
        }
        XCTAssertTrue(restored)
    }

    func testRestoreRefusedWhileSaveIsPending() throws {
        let pair = try makeVaultPair()
        let store = ControllableVaultStore(
            directory: dir,
            manager: VaultBackupManager(directory: dir.appendingPathComponent("backups"), defaults: pair.defaults))
        let session = VaultSession(fileStore: store)
        try session.unlock(password: "new-password")
        store.holdWrites()
        defer { store.releaseWrites() }
        session.mutate { $0.rootGroup.name = "changed" }
        XCTAssertThrowsError(try session.restoreBackup(from: pair.backupFile, defaults: pair.defaults)) {
            XCTAssertEqual($0 as? VaultSessionError, .writeInProgress)
        }
    }

    func testRestoreWritesBackupSnapshotsCurrentAndLocks() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaults = BackupTestDefaults.make()
        func makeStore() -> VaultFileStore {
            VaultFileStore(directory: dir, backupManager: VaultBackupManager(directory: dir.appendingPathComponent("backups"), defaults: defaults))
        }
        let first = VaultSession(fileStore: makeStore())
        try first.unlock(password: "old-password")
        let oldBytes = try Data(contentsOf: dir.appendingPathComponent("vault.kdbx"))
        let backupFile = dir.appendingPathComponent("chosen.kdbx")
        try oldBytes.write(to: backupFile)
        first.lock()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("vault.kdbx"))

        let session = VaultSession(fileStore: makeStore())
        try session.unlock(password: "new-password")
        let currentBytes = try Data(contentsOf: dir.appendingPathComponent("vault.kdbx"))
        XCTAssertNotEqual(currentBytes, oldBytes)

        try session.restoreBackup(from: backupFile, defaults: defaults)

        XCTAssertEqual(session.state, .locked)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("vault.kdbx")), oldBytes)
        let snapshots = try session.backupManager!.list().map { try Data(contentsOf: $0.url) }
        XCTAssertEqual(snapshots.filter { $0 == currentBytes }.count, 1, "current content snapshotted exactly once")
        // The restored vault opens with the backup's own password.
        XCTAssertNoThrow(try session.unlock(password: "old-password"))
    }

    func testRestoreRejectsNonVaultFileAndStoresWithoutBackups() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bogus = dir.appendingPathComponent("bogus.kdbx")
        try Data("not a vault at all".utf8).write(to: bogus)
        let defaults = BackupTestDefaults.make()
        let store = VaultFileStore(directory: dir, backupManager: VaultBackupManager(directory: dir.appendingPathComponent("backups"), defaults: defaults))
        let session = VaultSession(fileStore: store)
        XCTAssertThrowsError(try session.restoreBackup(from: bogus)) {
            XCTAssertEqual($0 as? VaultSessionError, .invalidBackup)
        }
        final class NoBackupStore: VaultPrimaryStorage {
            var primaryVaultFileURL: URL? { nil }
            func load() throws -> Data? { nil }
            func save(data: Data) throws {}
            func deleteVaultFileIfPresent() throws {}
        }
        XCTAssertThrowsError(try VaultSession(fileStore: NoBackupStore()).restoreBackup(from: bogus)) {
            XCTAssertEqual($0 as? VaultSessionError, .backupsUnavailable)
        }
    }
}
