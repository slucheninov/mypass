import XCTest
@testable import MyPass

final class KernelProcessTableTests: XCTestCase {
    func testCurrentProcessHasAnIdentity() throws {
        let me = try XCTUnwrap(KernelProcessTable.current)
        XCTAssertEqual(me.pid, getpid())
        XCTAssertGreaterThan(me.startMicroseconds, 0)
        XCTAssertTrue(KernelProcessTable.isAlive(me))
    }

    func testNonexistentAndInvalidPidsHaveNoIdentity() {
        XCTAssertNil(KernelProcessTable.identity(ofPID: 0))
        XCTAssertNil(KernelProcessTable.identity(ofPID: -5))
        XCTAssertNil(KernelProcessTable.identity(ofPID: Int32.max))
    }

    func testLivenessRequiresTheSameStartTime() throws {
        let me = try XCTUnwrap(KernelProcessTable.current)
        let recycledPidLookalike = ProcessIdentity(pid: me.pid, startMicroseconds: me.startMicroseconds + 1)
        XCTAssertFalse(KernelProcessTable.isAlive(recycledPidLookalike))
    }

    func testChildIsAliveThenGoneAfterItExits() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }

        let identity = try XCTUnwrap(KernelProcessTable.identity(ofPID: child.processIdentifier))
        XCTAssertTrue(KernelProcessTable.isAlive(identity))
        let me = try XCTUnwrap(KernelProcessTable.current)
        XCTAssertGreaterThanOrEqual(identity.startMicroseconds, me.startMicroseconds, "the child started after this process")

        child.terminate()
        child.waitUntilExit()
        XCTAssertFalse(KernelProcessTable.isAlive(identity))
    }
}
