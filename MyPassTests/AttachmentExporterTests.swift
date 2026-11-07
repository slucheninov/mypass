import MyPassKit
import XCTest
@testable import MyPass

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

    func testWriteFailureIsThrown() {
        let url = dir.appendingPathComponent("missing/out.txt")
        XCTAssertThrowsError(try AttachmentExporter(panel: FakePanel(destination: url)).export(attachment()))
    }

    func testExportCreatesNoOtherFilesInTemporaryDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: tmp.path))
        // The destination lives in `dir` (itself inside tmp); only that subtree may change.
        let url = dir.appendingPathComponent("out.bin")
        try AttachmentExporter(panel: FakePanel(destination: url)).export(attachment())
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: tmp.path))
        XCTAssertEqual(after, before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["out.bin"])
    }
}
