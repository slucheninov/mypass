import XCTest
@testable import MyPass

final class LocalFileVaultStoreTests: XCTestCase {
    var tempDir: URL!
    var vaultFileURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFileVaultStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        vaultFileURL = tempDir.appendingPathComponent("my-vault.kdbx")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLoadReturnsNilBeforeAnyWrite() throws {
        try Data("seed".utf8).write(to: vaultFileURL)
        let bookmark = try LocalFileVaultStore.createFileBookmark(for: vaultFileURL)
        let store = try LocalFileVaultStore(bookmarkData: bookmark)
        try FileManager.default.removeItem(at: vaultFileURL)
        XCTAssertNil(try store.load())
    }

    func testSaveThenLoadRoundTripsThroughBookmark() throws {
        try Data("seed".utf8).write(to: vaultFileURL)
        let bookmark = try LocalFileVaultStore.createFileBookmark(for: vaultFileURL)
        let store = try LocalFileVaultStore(bookmarkData: bookmark)
        try store.save(data: Data("local-file-round-trip".utf8))
        XCTAssertEqual(try store.load(), Data("local-file-round-trip".utf8))
        XCTAssertEqual(store.primaryVaultFileURL?.path, vaultFileURL.path)
    }

    func testDeleteVaultFileIfPresentRemovesFile() throws {
        try Data("seed".utf8).write(to: vaultFileURL)
        let bookmark = try LocalFileVaultStore.createFileBookmark(for: vaultFileURL)
        let store = try LocalFileVaultStore(bookmarkData: bookmark)
        try store.save(data: Data("to-delete".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vaultFileURL.path))
        try store.deleteVaultFileIfPresent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultFileURL.path))
    }
}
