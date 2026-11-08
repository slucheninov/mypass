import XCTest
@testable import MyPass

final class VaultFileStatusTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("VaultFileStatusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testExistingFileIsConnectedWithSizeAndDate() throws {
        let url = dir.appendingPathComponent("v.kdbx")
        try Data(repeating: 7, count: 2048).write(to: url)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)

        let status = VaultFileStatus.resolve(primaryURL: url, isDefaultLocation: false, fallbackActive: false)
        guard case .connected(let info) = status else { return XCTFail("expected connected, got \(status)") }
        XCTAssertEqual(info.fileName, "v.kdbx")
        XCTAssertEqual(info.size, 2048)
        XCTAssertEqual(try XCTUnwrap(info.modified).timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1)
        XCTAssertNotNil(info.summary)
        XCTAssertNotNil(info.sizeText)
    }

    func testMissingDefaultFileIsNoVault() {
        let url = dir.appendingPathComponent("vault.kdbx")
        XCTAssertEqual(VaultFileStatus.resolve(primaryURL: url, isDefaultLocation: true, fallbackActive: false), .noVault)
    }

    func testNoURLIsNoVault() {
        XCTAssertEqual(VaultFileStatus.resolve(primaryURL: nil, isDefaultLocation: true, fallbackActive: false), .noVault)
    }

    func testMissingConfiguredFileReportsItsPath() {
        let url = dir.appendingPathComponent("gone.kdbx")
        XCTAssertEqual(
            VaultFileStatus.resolve(primaryURL: url, isDefaultLocation: false, fallbackActive: false),
            .missing(path: url.path)
        )
    }

    func testFallbackIsMissingEvenWhenTheDefaultFileExists() throws {
        let url = dir.appendingPathComponent("vault.kdbx")
        try Data([1]).write(to: url)
        XCTAssertEqual(
            VaultFileStatus.resolve(primaryURL: url, isDefaultLocation: true, fallbackActive: true),
            .missing(path: nil)
        )
    }

    func testDirectoryIsNotAVaultFile() throws {
        XCTAssertEqual(VaultFileStatus.resolve(primaryURL: dir, isDefaultLocation: true, fallbackActive: false), .noVault)
    }

    func testAbbreviatedPathUsesTheGivenHome() {
        XCTAssertEqual(VaultFileInfo.abbreviatedPath("/Users/me/Documents/a.kdbx", home: "/Users/me"), "~/Documents/a.kdbx")
        XCTAssertEqual(VaultFileInfo.abbreviatedPath("/Users/me", home: "/Users/me"), "~")
        XCTAssertEqual(VaultFileInfo.abbreviatedPath("/Users/meh/a.kdbx", home: "/Users/me"), "/Users/meh/a.kdbx")
        XCTAssertEqual(VaultFileInfo.abbreviatedPath("/Volumes/X/a.kdbx", home: "/Users/me"), "/Volumes/X/a.kdbx")
    }
}
