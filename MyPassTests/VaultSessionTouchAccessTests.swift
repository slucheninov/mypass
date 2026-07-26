import XCTest
import MyPassKit
@testable import MyPass

final class VaultSessionTouchAccessTests: XCTestCase {
    var tempDir: URL!
    var fileStore: VaultFileStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TouchAccessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileStore = VaultFileStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testTouchAccessUpdatesLastAccessTimeInMemory() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "pw")
        let entryID = UUID()
        let oldAccess = Date(timeIntervalSince1970: 1_000)
        session.mutate { db in
            var entry = KdbxEntry(
                uuid: entryID, iconID: 0, fields: [],
                creationTime: oldAccess, lastModificationTime: oldAccess,
                lastAccessTime: oldAccess, locationChanged: oldAccess, history: []
            )
            entry.title = "GitHub"
            db.rootGroup.entries.append(entry)
        }

        session.touchAccess(entryID: entryID)

        guard case .unlocked(let db) = session.state,
              let updated = GroupTreeOperations.entryLocation(entryID: entryID, in: db.rootGroup) else {
            return XCTFail("entry not found")
        }
        XCTAssertGreaterThan(db.rootGroup.entries[updated.index].lastAccessTime, oldAccess)
    }

    func testTouchAccessDebouncedPersistWritesToDisk() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "pw")
        let entryID = UUID()
        let oldAccess = Date(timeIntervalSince1970: 1_000)
        session.mutate { db in
            var entry = KdbxEntry(
                uuid: entryID, iconID: 0, fields: [],
                creationTime: oldAccess, lastModificationTime: oldAccess,
                lastAccessTime: oldAccess, locationChanged: oldAccess, history: []
            )
            entry.title = "GitHub"
            db.rootGroup.entries.append(entry)
        }
        // Let the mutate-triggered persist finish so it cannot race the debounced save.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        session.touchAccess(entryID: entryID)

        let deadline = Date().addingTimeInterval(5)
        var persisted = false
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            guard let data = try fileStore.load() else { continue }
            let reloaded = try KdbxDatabase.open(data: data, password: "pw")
            guard let location = GroupTreeOperations.entryLocation(entryID: entryID, in: reloaded.rootGroup) else {
                continue
            }
            if reloaded.rootGroup.entries[location.index].lastAccessTime > oldAccess {
                persisted = true
                break
            }
        }
        XCTAssertTrue(persisted, "debounced touchAccess should persist lastAccessTime to disk")
    }

    func testTouchAccessNoOpWhenLocked() {
        let session = VaultSession(fileStore: fileStore)
        session.touchAccess(entryID: UUID()) // must not crash
        XCTAssertEqual(session.state, .locked)
    }
}
