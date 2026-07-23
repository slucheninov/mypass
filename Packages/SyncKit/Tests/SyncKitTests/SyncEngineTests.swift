import XCTest
import MyPassKit
@testable import SyncKit

final class SyncEngineTests: XCTestCase {
    let password = "sync-engine-tests-password"

    /// `KdbxEntry.title` isn't visible from `SyncKitTests` — it's an
    /// app-level convenience extension declared in
    /// `MyPass/Models/KdbxEntry+Convenience.swift`, part of the `MyPass`
    /// app target, not `MyPassKit` — so these tests read "Title" directly
    /// via `fields`, exactly as `KdbxEntry` itself exposes it.
    func titleFieldValue(of entry: KdbxEntry) -> String? {
        entry.fields.first(where: { $0.key == "Title" })?.value
    }

    func makeEntry(title: String, uuid: UUID = UUID(), modified: Date = Date(timeIntervalSince1970: 1_000)) -> KdbxEntry {
        KdbxEntry(
            uuid: uuid,
            iconID: 0,
            fields: [KdbxField(key: "Title", value: title, isProtected: false)],
            creationTime: modified,
            lastModificationTime: modified,
            lastAccessTime: modified,
            locationChanged: modified,
            history: []
        )
    }

    /// Always constructs a brand-new `KdbxGroup` (a *reference* type) so two
    /// "copies" built from separate calls never secretly alias the same
    /// underlying group object.
    func makeDatabase(rootUUID: UUID, entries: [KdbxEntry], recycleBinGroupUUID: UUID? = nil) -> KdbxDatabase {
        let now = Date(timeIntervalSince1970: 1_000)
        let root = KdbxGroup(
            uuid: rootUUID,
            name: "MyPass",
            iconID: 0,
            creationTime: now,
            lastModificationTime: now,
            locationChanged: now,
            entries: entries,
            subgroups: []
        )
        return KdbxDatabase(rootGroup: root, deletedObjects: [], recycleBinGroupUUID: recycleBinGroupUUID)
    }

    func testFirstSyncBackendDoesNotExistUploadsLocal() throws {
        let rootUUID = UUID()
        let local = makeDatabase(rootUUID: rootUUID, entries: [makeEntry(title: "OnlyLocal")])
        let remote = InMemoryStorageBackend()
        let checkpointStore = InMemorySyncCheckpointStore()
        let engine = SyncEngine(remote: remote, checkpointStore: checkpointStore)

        XCTAssertFalse(try remote.exists())

        let result = try engine.sync(local: local, password: password, cipher: .aes256, compression: .gzip)

        guard case .uploadedInitial = result else {
            return XCTFail("expected .uploadedInitial, got \(result)")
        }
        XCTAssertTrue(try remote.exists())
        let remoteData = try XCTUnwrap(try remote.read())
        let remoteDatabase = try KdbxDatabase.open(data: remoteData, password: password)
        XCTAssertEqual(titleFieldValue(of: remoteDatabase.rootGroup.entries.first!), "OnlyLocal")
        XCTAssertNotNil(try checkpointStore.loadCheckpoint())
    }

    func testUnchangedRemoteReuploadsLocalDirectly() throws {
        let rootUUID = UUID()
        let firstEntry = makeEntry(title: "First")
        let firstLocal = makeDatabase(rootUUID: rootUUID, entries: [firstEntry])
        let remote = InMemoryStorageBackend()
        let checkpointStore = InMemorySyncCheckpointStore()
        let engine = SyncEngine(remote: remote, checkpointStore: checkpointStore)

        _ = try engine.sync(local: firstLocal, password: password, cipher: .aes256, compression: .gzip)
        let checkpointAfterFirstSync = try XCTUnwrap(try checkpointStore.loadCheckpoint())

        // A brand-new database value with an extra entry.
        let secondEntry = makeEntry(title: "Second")
        let secondLocal = makeDatabase(rootUUID: rootUUID, entries: [firstEntry, secondEntry])

        let result = try engine.sync(local: secondLocal, password: password, cipher: .aes256, compression: .gzip)

        guard case .uploadedDirect = result else {
            return XCTFail("expected .uploadedDirect, got \(result)")
        }
        let remoteData = try XCTUnwrap(try remote.read())
        let remoteDatabase = try KdbxDatabase.open(data: remoteData, password: password)
        XCTAssertEqual(remoteDatabase.rootGroup.entries.count, 2)
        let checkpointAfterSecondSync = try XCTUnwrap(try checkpointStore.loadCheckpoint())
        XCTAssertNotEqual(checkpointAfterFirstSync, checkpointAfterSecondSync)
    }

    func testChangedRemoteTriggersMerge() throws {
        let rootUUID = UUID()
        let sharedEntry = makeEntry(title: "Shared", uuid: UUID())
        let firstLocal = makeDatabase(rootUUID: rootUUID, entries: [sharedEntry])
        let remote = InMemoryStorageBackend()
        let checkpointStore = InMemorySyncCheckpointStore()
        let engine = SyncEngine(remote: remote, checkpointStore: checkpointStore)

        _ = try engine.sync(local: firstLocal, password: password, cipher: .aes256, compression: .gzip)

        // Simulate a second device writing to the SAME remote.
        let remoteOnlyEntry = makeEntry(title: "RemoteOnly", uuid: UUID(), modified: Date(timeIntervalSince1970: 5_000))
        let remoteDatabaseFromOtherDevice = makeDatabase(rootUUID: rootUUID, entries: [sharedEntry, remoteOnlyEntry])
        let remoteDataFromOtherDevice = try remoteDatabaseFromOtherDevice.save(password: password, cipher: .aes256, compression: .gzip)
        try remote.write(remoteDataFromOtherDevice)

        let localOnlyEntry = makeEntry(title: "LocalOnly", uuid: UUID(), modified: Date(timeIntervalSince1970: 6_000))
        let secondLocal = makeDatabase(rootUUID: rootUUID, entries: [sharedEntry, localOnlyEntry])

        let result = try engine.sync(local: secondLocal, password: password, cipher: .aes256, compression: .gzip)

        guard case .merged(let mergedDatabase) = result else {
            return XCTFail("expected .merged, got \(result)")
        }
        let mergedTitles = Set(mergedDatabase.rootGroup.entries.compactMap { titleFieldValue(of: $0) })
        XCTAssertEqual(mergedTitles, ["Shared", "RemoteOnly", "LocalOnly"])

        let remoteData = try XCTUnwrap(try remote.read())
        let remoteDatabaseAfterSync = try KdbxDatabase.open(data: remoteData, password: password)
        let uploadedTitles = Set(remoteDatabaseAfterSync.rootGroup.entries.compactMap { titleFieldValue(of: $0) })
        XCTAssertEqual(uploadedTitles, mergedTitles)
    }

    func testMidCycleFailureLeavesCheckpointAndLocalUntouched() throws {
        let rootUUID = UUID()
        let firstLocal = makeDatabase(rootUUID: rootUUID, entries: [makeEntry(title: "First")])
        let remote = InMemoryStorageBackend()
        let checkpointStore = InMemorySyncCheckpointStore()
        let engine = SyncEngine(remote: remote, checkpointStore: checkpointStore)

        _ = try engine.sync(local: firstLocal, password: password, cipher: .aes256, compression: .gzip)
        let checkpointBeforeFailure = try checkpointStore.loadCheckpoint()
        let remoteDataBeforeFailure = try remote.read()

        struct SimulatedNetworkError: Error {}
        remote.writeError = SimulatedNetworkError()

        let secondLocal = makeDatabase(rootUUID: rootUUID, entries: [makeEntry(title: "SecondA"), makeEntry(title: "SecondB")])

        XCTAssertThrowsError(try engine.sync(local: secondLocal, password: password, cipher: .aes256, compression: .gzip)) { error in
            XCTAssertTrue(error is SimulatedNetworkError)
        }

        XCTAssertEqual(try checkpointStore.loadCheckpoint(), checkpointBeforeFailure)
        XCTAssertEqual(try remote.read(), remoteDataBeforeFailure)
        XCTAssertEqual(secondLocal.rootGroup.entries.count, 2)
    }
}
