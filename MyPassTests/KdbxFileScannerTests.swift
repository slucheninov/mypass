import XCTest
@testable import MyPass

final class KdbxFileScannerTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("KdbxFileScannerTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func touch(_ relativePath: String, bytes: Int = 4, modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    private func names(_ files: [FoundVaultFile]) -> [String] { files.map { $0.url.lastPathComponent } }

    func testFindsNestedFilesAndIgnoresCase() throws {
        try touch("a.kdbx")
        try touch("deep/er/b.KDBX")
        try touch("notes.txt")
        try touch("c.kdbx.bak")
        XCTAssertEqual(Set(names(KdbxFileScanner().scan(folder: root))), ["a.kdbx", "b.KDBX"])
    }

    func testReportsSizeAndModificationDate() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try touch("a.kdbx", bytes: 123, modified: date)
        let found = try XCTUnwrap(KdbxFileScanner().scan(folder: root).first)
        XCTAssertEqual(found.size, 123)
        XCTAssertEqual(found.modified.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1)
        XCTAssertFalse(found.isCloudPlaceholder)
    }

    func testSkipsHiddenDirectoriesAndFiles() throws {
        try touch(".git/x.kdbx")
        try touch(".hidden/y.kdbx")
        try touch(".z.kdbx")
        try touch("ok.kdbx")
        XCTAssertEqual(names(KdbxFileScanner().scan(folder: root)), ["ok.kdbx"])
    }

    func testSkipsBundlesAndNodeModules() throws {
        try touch("Some.app/Contents/x.kdbx")
        try touch("Photos.photoslibrary/y.kdbx")
        try touch("proj/node_modules/pkg/z.kdbx")
        try touch("proj/real.kdbx")
        XCTAssertEqual(names(KdbxFileScanner().scan(folder: root)), ["real.kdbx"])
    }

    func testDoesNotFollowSymlinks() throws {
        try touch("target/inside.kdbx")
        // A loop back to the root and a link to a directory and to a file.
        try fm.createSymbolicLink(at: root.appendingPathComponent("target/loop"), withDestinationURL: root)
        try fm.createSymbolicLink(at: root.appendingPathComponent("dirlink"), withDestinationURL: root.appendingPathComponent("target"))
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("filelink.kdbx"),
            withDestinationURL: root.appendingPathComponent("target/inside.kdbx")
        )
        XCTAssertEqual(names(KdbxFileScanner().scan(folder: root)), ["inside.kdbx"])
    }

    func testRespectsMaxDepth() throws {
        try touch("a.kdbx")                 // level 0
        try touch("d1/b.kdbx")              // level 1
        try touch("d1/d2/c.kdbx")           // level 2
        try touch("d1/d2/d3/d.kdbx")        // level 3
        var scanner = KdbxFileScanner()
        scanner.limits.maxDepth = 2
        XCTAssertEqual(Set(names(scanner.scan(folder: root))), ["a.kdbx", "b.kdbx", "c.kdbx"])
        scanner.limits.maxDepth = 0
        XCTAssertEqual(names(scanner.scan(folder: root)), ["a.kdbx"])
    }

    func testRespectsResultCap() throws {
        for index in 0..<10 { try touch("f\(index).kdbx") }
        var scanner = KdbxFileScanner()
        scanner.limits.maxResults = 3
        XCTAssertEqual(scanner.scan(folder: root).count, 3)
    }

    func testSortsNewestFirst() throws {
        try touch("old.kdbx", modified: Date(timeIntervalSince1970: 1_000_000_000))
        try touch("new.kdbx", modified: Date(timeIntervalSince1970: 1_700_000_000))
        try touch("mid/mid.kdbx", modified: Date(timeIntervalSince1970: 1_500_000_000))
        XCTAssertEqual(names(KdbxFileScanner().scan(folder: root)), ["new.kdbx", "mid.kdbx", "old.kdbx"])
    }

    func testCancellationStopsTheScan() throws {
        try touch("a.kdbx")
        XCTAssertTrue(KdbxFileScanner().scan(folder: root, isCancelled: { true }).isEmpty)
    }

    func testExhaustedTimeBudgetStopsTheScan() throws {
        try touch("a.kdbx")
        var scanner = KdbxFileScanner()
        scanner.limits.timeBudget = -1
        XCTAssertTrue(scanner.scan(folder: root).isEmpty)
    }

    func testHomeScanCoversPriorityFoldersAndSkipsLibrary() throws {
        try touch("Documents/doc.kdbx")
        try touch("Library/Mobile Documents/com~apple~CloudDocs/icloud.kdbx")
        try touch("Library/CloudStorage/Dropbox-Personal/drop.kdbx")
        try touch("Library/Caches/junk.kdbx")
        try touch("Projects/proj.kdbx")
        let found = KdbxFileScanner().scan(folder: root, home: root)
        XCTAssertEqual(Set(names(found)), ["doc.kdbx", "icloud.kdbx", "drop.kdbx", "proj.kdbx"])
        XCTAssertEqual(found.count, 4, "Priority folders must not be listed twice")
    }

    func testSymlinkedPriorityRootIsScannedOnce() throws {
        try touch("Library/CloudStorage/Dropbox-Personal/drop.kdbx")
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("Dropbox"),
            withDestinationURL: root.appendingPathComponent("Library/CloudStorage/Dropbox-Personal")
        )
        let found = KdbxFileScanner().scan(folder: root, home: root)
        XCTAssertEqual(names(found), ["drop.kdbx"])
    }

    func testCancellingTheCallingTaskStopsTheDetachedScan() async throws {
        for index in 0..<300 { try touch("f\(index).kdbx") }
        let visits = Counter()
        let task = Task {
            // Slow poll so the full scan would take ~3 s if cancellation did not reach it.
            await KdbxFileScanner().scanAsync(folder: root, isCancelled: {
                visits.increment()
                Thread.sleep(forTimeInterval: 0.01)
                return false
            })
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let started = Date()
        task.cancel()
        _ = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertLessThan(visits.value, 200)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    func testNonHomeFolderDoesNotSkipLibrary() throws {
        try touch("Library/x.kdbx")
        XCTAssertEqual(names(KdbxFileScanner().scan(folder: root, home: root.appendingPathComponent("elsewhere"))), ["x.kdbx"])
    }
}
