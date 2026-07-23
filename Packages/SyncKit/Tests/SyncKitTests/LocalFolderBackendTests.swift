import XCTest
@testable import SyncKit

final class LocalFolderBackendTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncKitLocalFolderBackendTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testExistsIsFalseBeforeAnyWrite() throws {
        let bookmark = try LocalFolderBackend.createBookmark(for: tempDir)
        let backend = try LocalFolderBackend(bookmarkData: bookmark)
        XCTAssertFalse(try backend.exists())
        XCTAssertNil(try backend.read())
    }

    func testWriteThenReadRoundTripsExactBytes() throws {
        let bookmark = try LocalFolderBackend.createBookmark(for: tempDir)
        let backend = try LocalFolderBackend(bookmarkData: bookmark)
        let payload = Data("kdbx-bytes-example".utf8)
        try backend.write(payload)
        XCTAssertTrue(try backend.exists())
        XCTAssertEqual(try backend.read(), payload)
    }

    func testModificationDateIsNonNilAfterWriteAndIncreasesOnSecondWrite() throws {
        let bookmark = try LocalFolderBackend.createBookmark(for: tempDir)
        let backend = try LocalFolderBackend(bookmarkData: bookmark)
        try backend.write(Data("v1".utf8))
        let firstDate = try backend.modificationDate()
        XCTAssertNotNil(firstDate)

        Thread.sleep(forTimeInterval: 1.0)
        try backend.write(Data("v2".utf8))
        let secondDate = try backend.modificationDate()
        XCTAssertNotNil(secondDate)
        XCTAssertGreaterThan(secondDate!, firstDate!)
    }

    func testSecondWriteOverwritesFirst() throws {
        let bookmark = try LocalFolderBackend.createBookmark(for: tempDir)
        let backend = try LocalFolderBackend(bookmarkData: bookmark)
        try backend.write(Data("first".utf8))
        try backend.write(Data("second".utf8))
        XCTAssertEqual(try backend.read(), Data("second".utf8))
    }
}
