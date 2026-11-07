import MyPassKit
import XCTest
@testable import MyPass

@MainActor
final class AttachmentExporterTests: XCTestCase {
    private final class FakePanel: SavePanelPresenting {
        var destination: URL?
        private(set) var suggestedNames: [String] = []
        init(destination: URL?) { self.destination = destination }
        func chooseDestination(suggestedName: String) -> URL? {
            suggestedNames.append(suggestedName)
            return destination
        }
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func attachment(_ name: String = "a.txt", _ bytes: [UInt8] = [1, 2, 3]) -> KdbxAttachment {
        KdbxAttachment(name: name, data: Data(bytes), isProtected: true)
    }

    func testCancelWritesNothing() throws {
        let result = try AttachmentExporter(panel: FakePanel(destination: nil)).export(attachment())
        XCTAssertNil(result)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    func testWritesExactBytesToChosenURL() throws {
        let url = dir.appendingPathComponent("out.bin")
        let bytes = (0...255).map { UInt8($0) }
        let result = try AttachmentExporter(panel: FakePanel(destination: url)).export(attachment("x.bin", bytes))
        XCTAssertEqual(result, url)
        XCTAssertEqual(try Data(contentsOf: url), Data(bytes))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["out.bin"])
    }

    func testSuggestedNameIsSanitized() throws {
        let panel = FakePanel(destination: nil)
        _ = try AttachmentExporter(panel: panel).export(attachment("../a/b.txt"))
        XCTAssertEqual(panel.suggestedNames, ["b.txt"])
    }

    private func listing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    func testWriteFailureIsThrownAndLeavesNoStrayFiles() throws {
        let url = dir.appendingPathComponent("missing/out.txt")
        XCTAssertThrowsError(try AttachmentExporter(panel: FakePanel(destination: url)).export(attachment()))
        XCTAssertEqual(try listing(), [])
    }

    func testRenameFailureCleansUpStagingFile() throws {
        // Renaming a file over an existing directory fails after staging succeeded.
        let url = dir.appendingPathComponent("taken")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try AttachmentExporter(panel: FakePanel(destination: url)).export(attachment()))
        XCTAssertEqual(try listing(), ["taken"])
        XCTAssertFalse(try listing().contains { $0.contains(".mypass-") })
    }

    func testSuccessLeavesOnlyTheDestinationInItsDirectory() throws {
        let url = dir.appendingPathComponent("out.bin")
        try AttachmentExporter(panel: FakePanel(destination: url)).export(attachment())
        XCTAssertEqual(try listing(), ["out.bin"])
    }

    func testExportedFileModeIs0600() throws {
        let url = dir.appendingPathComponent("out.bin")
        try AttachmentExporter(panel: FakePanel(destination: url)).export(attachment())
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func testOverwritesExistingDestination() throws {
        let url = dir.appendingPathComponent("out.bin")
        try Data([9, 9, 9, 9, 9]).write(to: url)
        try AttachmentExporter(panel: FakePanel(destination: url)).export(attachment())
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
        XCTAssertEqual(try listing(), ["out.bin"])
    }

    func testVeryLongDestinationNameStillExports() throws {
        // 200 bytes is under NAME_MAX (255) but a name-derived staging template
        // (dot + name + suffix) would exceed it and fail with ENAMETOOLONG.
        let url = dir.appendingPathComponent(String(repeating: "a", count: 240))
        try AttachmentExporter(panel: FakePanel(destination: url)).export(attachment())
        XCTAssertEqual(try listing(), [url.lastPathComponent])
    }
}
