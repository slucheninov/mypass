import XCTest
@testable import MyPass

final class VaultICloudFolderSelectionTests: XCTestCase {
    var baseDir: URL!

    override func setUpWithError() throws {
        baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultICloudFolderSelectionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: baseDir)
    }

    func testMyPassCaseInsensitiveNamesUseFolderAsIs() throws {
        for name in ["MyPass", "mypass", "MYPASS"] {
            let folder = baseDir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let resolved = try VaultICloudFolderSelection.resolveVaultFolder(from: folder)
            XCTAssertEqual(resolved.path, folder.path, "expected no nesting for \(name)")
            try FileManager.default.removeItem(at: folder)
        }
    }

    func testExistingVaultAtPickedRootUsesFolderAsIs() throws {
        let folder = baseDir.appendingPathComponent("CustomSync", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("vault".utf8).write(to: folder.appendingPathComponent("vault.kdbx"))
        let resolved = try VaultICloudFolderSelection.resolveVaultFolder(from: folder)
        XCTAssertEqual(resolved.path, folder.path)
    }

    func testOtherwiseCreatesMyPassSubfolder() throws {
        let folder = baseDir.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let resolved = try VaultICloudFolderSelection.resolveVaultFolder(from: folder)
        XCTAssertEqual(resolved.lastPathComponent, "MyPass")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
    }
}
