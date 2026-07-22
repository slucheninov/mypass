import XCTest
@testable import MyPass

final class VaultFileStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPassVaultFileStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLoadReturnsNilWhenNoVaultExists() throws {
        let store = VaultFileStore(directory: tempDir)
        XCTAssertNil(try store.load())
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = VaultFileStore(directory: tempDir)
        let payload = Data("hello vault".utf8)
        try store.save(data: payload)
        XCTAssertEqual(try store.load(), payload)
    }

    func testBackupRotationKeepsOnlyBackupCountFiles() throws {
        let store = VaultFileStore(directory: tempDir, backupCount: 2)
        for i in 0..<5 {
            try store.save(data: Data("version \(i)".utf8))
        }
        let backupsDir = tempDir.appendingPathComponent("backups")
        let backups = try FileManager.default.contentsOfDirectory(atPath: backupsDir.path)
        XCTAssertEqual(backups.count, 2)
    }

    func testConcurrentSavesDoNotCorruptVaultOrThrow() throws {
        let store = VaultFileStore(directory: tempDir)
        let iterations = 30
        let payloads = (0..<iterations).map { Data("payload-\($0)".utf8) }
        let errorsLock = NSLock()
        var thrownErrors: [Error] = []

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            do {
                try store.save(data: payloads[index])
            } catch {
                errorsLock.lock()
                thrownErrors.append(error)
                errorsLock.unlock()
            }
        }

        XCTAssertTrue(thrownErrors.isEmpty, "save() threw under concurrency: \(thrownErrors)")

        let finalData = try store.load()
        XCTAssertNotNil(finalData, "vault file should be readable after concurrent saves")
        XCTAssertTrue(
            payloads.contains(finalData!),
            "final vault contents should exactly match one of the written payloads, not a corrupted mix"
        )
    }
}
