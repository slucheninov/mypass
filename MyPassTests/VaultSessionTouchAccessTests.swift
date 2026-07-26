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

    func testTouchAccessUpdatesLastAccessTimeAndPersists() throws {
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

        Thread.sleep(forTimeInterval: 0.05) // allow async persist to queue
        session.touchAccess(entryID: entryID)

        guard case .unlocked(let db) = session.state,
              let updated = GroupTreeOperations.entryLocation(entryID: entryID, in: db.rootGroup) else {
            return XCTFail("entry not found")
        }
        XCTAssertGreaterThan(db.rootGroup.entries[updated.index].lastAccessTime, oldAccess)
    }

    func testTouchAccessNoOpWhenLocked() {
        let session = VaultSession(fileStore: fileStore)
        session.touchAccess(entryID: UUID()) // must not crash
        XCTAssertEqual(session.state, .locked)
    }
}
