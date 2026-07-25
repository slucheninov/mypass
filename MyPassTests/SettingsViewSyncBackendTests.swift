import XCTest
import SyncKit
@testable import MyPass

final class SettingsViewSyncBackendTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsViewSyncBackendTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testResolveLocalFolderBackendReturnsWorkingBackendForValidBookmark() throws {
        let bookmark = try LocalFolderBackend.createBookmark(for: tempDir)
        let backend = SyncBackendResolver.resolveLocalFolderBackend(bookmarkData: bookmark)
        let resolved = try XCTUnwrap(backend)

        XCTAssertFalse(try resolved.exists())
        try resolved.write(Data("resolved-backend-round-trip".utf8))
        XCTAssertEqual(try resolved.read(), Data("resolved-backend-round-trip".utf8))
    }

    func testResolveLocalFolderBackendReturnsNilForMissingBookmark() {
        XCTAssertNil(SyncBackendResolver.resolveLocalFolderBackend(bookmarkData: nil))
        XCTAssertNil(SyncBackendResolver.resolveLocalFolderBackend(bookmarkData: Data()))
    }

    func testResolveLocalFolderBackendReturnsNilForInvalidBookmarkDataWithoutCrashing() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE])
        XCTAssertNil(SyncBackendResolver.resolveLocalFolderBackend(bookmarkData: garbage))
    }
}
