import XCTest
import MyPassKit
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

        // Capture the on-disk bytes as they existed right after unlock (first-run
        // creation autosave), so we can detect once the *mutation's* autosave —
        // which now happens on a background queue — has actually landed on disk.
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

        // mutate() updates in-memory state synchronously, but persist() now dispatches
        // the KDF derivation + file write to a background queue. Poll the file on disk
        // (short interval, small cap) until it changes from the pre-mutation snapshot,
        // rather than asserting immediately — this avoids a race against the async save
        // without introducing a long fixed sleep.
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

        // A brand-new session pointed at the SAME fileStore/directory must be able to
        // unlock with the same password and see the mutation persisted to disk — this
        // is the end-to-end proof that mutate() now autosaves rather than only ever
        // writing once at first-run creation time.
        let secondSession = VaultSession(fileStore: fileStore)
        try secondSession.unlock(password: "correct-horse")
        guard case .unlocked(let db) = secondSession.state else {
            return XCTFail("expected unlocked state")
        }
        XCTAssertEqual(db.rootGroup.entries.count, 1)
        XCTAssertEqual(db.rootGroup.entries.first?.title, "Mutated Entry")
    }
}
