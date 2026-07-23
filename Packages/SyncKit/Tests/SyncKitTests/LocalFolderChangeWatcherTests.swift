import XCTest
@testable import SyncKit

final class LocalFolderChangeWatcherTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncKitLocalFolderChangeWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testChangeInWatchedFolderFiresOnChange() throws {
        let expectation = XCTestExpectation(description: "onChange fires after file write")
        let watcher = LocalFolderChangeWatcher(folderURL: tempDir) {
            expectation.fulfill()
        }
        watcher.start()

        // Give FSEventStream a moment to register before mutating the folder.
        Thread.sleep(forTimeInterval: 0.5)
        try Data("changed".utf8).write(to: tempDir.appendingPathComponent("vault.kdbx"))

        wait(for: [expectation], timeout: 8.0)
        watcher.stop()
    }

    func testNoCallbackAfterStop() throws {
        var fireCount = 0
        let watcher = LocalFolderChangeWatcher(folderURL: tempDir) {
            fireCount += 1
        }
        watcher.start()
        Thread.sleep(forTimeInterval: 0.5)
        try Data("first".utf8).write(to: tempDir.appendingPathComponent("vault.kdbx"))
        Thread.sleep(forTimeInterval: 1.2) // allow debounce window to fire once

        watcher.stop()
        let countAfterStop = fireCount
        XCTAssertGreaterThanOrEqual(countAfterStop, 1)

        try Data("second".utf8).write(to: tempDir.appendingPathComponent("vault.kdbx"))
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertEqual(fireCount, countAfterStop, "no further callback should fire after stop()")
    }
}
