import XCTest
import Combine
@testable import MyPass

/// The quit-time freeze must be visible, and every app-owned quit action must go through
/// `AppDelegate.requestTermination`.
final class QuitFreezeUITests: XCTestCase {
    private var directory: URL!
    private var store: ControllableVaultStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuitFreezeUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ControllableVaultStore(directory: directory)
    }

    override func tearDownWithError() throws {
        store.releaseWrites()
        try? FileManager.default.removeItem(at: directory)
    }

    /// SwiftUI only redraws the "saving" overlay if the flag publishes; a plain stored property
    /// would freeze the session while the windows keep looking editable.
    func testQuitFreezePublishesToObserversOnFreezeAndOnCancel() throws {
        let session = VaultSession(fileStore: store)
        try session.unlock(password: "correct-horse")

        var changes = 0
        let subscription = session.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        let flushed = expectation(description: "flush completes")
        session.flushPendingWrites(timeout: 5) { _ in flushed.fulfill() }
        wait(for: [flushed], timeout: 5)
        XCTAssertTrue(session.isQuitInProgress)
        XCTAssertGreaterThan(changes, 0, "freezing the session must notify SwiftUI observers")

        let before = changes
        session.resumeAfterCancelledQuit()
        XCTAssertFalse(session.isQuitInProgress)
        XCTAssertGreaterThan(changes, before, "cancelling the quit must notify observers so the overlay goes away")
    }

    /// A second `NSApp.terminate` while a flush is pending makes AppKit exit at once and lose the
    /// flush (see `QuitFlushCoordinator.requestTermination`). The only code line allowed to call
    /// it is the default argument of `AppDelegate.requestTermination`.
    func testNoAppSourceTerminatesTheApplicationOutsideTheGuardedPath() throws {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MyPass")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                guard code.contains(".terminate(nil)") || code.contains(".terminate(self)") else { continue }
                if url.lastPathComponent == "AppDelegate.swift", code.contains("static func requestTermination") { continue }
                offenders.append("\(url.lastPathComponent): \(code)")
            }
        }
        XCTAssertEqual(offenders, [], "route quit actions through AppDelegate.requestTermination")
    }
}
