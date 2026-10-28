import AppKit
import XCTest
@testable import MyPass

@MainActor
final class EntryActionsCopyTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPassEntryActionsCopyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Copy Code on an entry whose one-time code cannot be generated used to write "" and
    /// wipe the user's clipboard. Observed through `changeCount`, so the test never has to
    /// put anything on (or take anything off) the real general pasteboard.
    func testCopyingAnEmptyValueLeavesThePasteboardUntouched() {
        let session = VaultSession(fileStore: VaultFileStore(directory: tempDir))
        let before = NSPasteboard.general.changeCount

        EntryActions.copy("", entryID: UUID(), in: session)

        XCTAssertEqual(NSPasteboard.general.changeCount, before)
    }
}
