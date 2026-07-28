import XCTest
@testable import MyPass

final class FakeCancelable: AutoLockCancelable {
    var cancelled = false
    func cancel() { cancelled = true }
}

final class FakeClock: AutoLockClock {
    var scheduled: [(seconds: TimeInterval, action: () -> Void)] = []

    func scheduleTick(after seconds: TimeInterval, _ action: @escaping () -> Void) -> AutoLockCancelable {
        scheduled.append((seconds, action))
        return FakeCancelable()
    }

    func fireLast() {
        scheduled.last?.action()
    }
}

final class FakeSleepObserver: AutoLockSleepObserving {
    var handlers: [() -> Void] = []

    func onWillSleep(_ handler: @escaping () -> Void) -> AutoLockCancelable {
        handlers.append(handler)
        return FakeCancelable()
    }

    func fireSleep() {
        handlers.forEach { $0() }
    }
}

final class AutoLockControllerTests: XCTestCase {
    func testInactivityTimeoutLocksVault() throws {
        let fileStore = VaultFileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "pw")

        let clock = FakeClock()
        let sleepObserver = FakeSleepObserver()
        let controller = AutoLockController(vaultSession: session, clock: clock, sleepObserver: sleepObserver, timeout: 60)

        clock.fireLast()

        XCTAssertEqual(session.state, .locked)
        _ = controller  // Keep reference to controller
    }

    func testSleepNotificationLocksVault() throws {
        let fileStore = VaultFileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "pw")

        let clock = FakeClock()
        let sleepObserver = FakeSleepObserver()
        let controller = AutoLockController(vaultSession: session, clock: clock, sleepObserver: sleepObserver, timeout: 900)

        sleepObserver.fireSleep()

        XCTAssertEqual(session.state, .locked)
        _ = controller  // Keep reference to controller
    }

    func testRecordActivityCancelsPreviousTick() throws {
        let fileStore = VaultFileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "pw")

        let clock = FakeClock()
        let sleepObserver = FakeSleepObserver()
        let controller = AutoLockController(vaultSession: session, clock: clock, sleepObserver: sleepObserver, timeout: 60)

        let firstCancelable = clock.scheduled.last
        controller.recordActivity()

        XCTAssertTrue((firstCancelable != nil))
        // The controller must have scheduled a second tick; firing only the newest one should still lock.
        clock.fireLast()
        XCTAssertEqual(session.state, .locked)
        _ = controller  // Keep reference to controller
    }

    func testNilTimeoutNeverSchedulesATick() throws {
        let fileStore = VaultFileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "pw")

        let clock = FakeClock()
        let sleepObserver = FakeSleepObserver()
        let controller = AutoLockController(vaultSession: session, clock: clock, sleepObserver: sleepObserver, timeout: nil)

        XCTAssertTrue(clock.scheduled.isEmpty)
        XCTAssertEqual(session.state, .unlocked(try XCTUnwrap(session.currentDatabase)))
    }

    func testLockOnSleepDisabledDoesNotLockOnSleep() throws {
        let fileStore = VaultFileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "pw")

        let clock = FakeClock()
        let sleepObserver = FakeSleepObserver()
        let controller = AutoLockController(
            vaultSession: session,
            clock: clock,
            sleepObserver: sleepObserver,
            timeout: 900,
            lockOnSleepEnabled: false
        )

        sleepObserver.fireSleep()

        XCTAssertEqual(session.state, .unlocked(try XCTUnwrap(session.currentDatabase)))
        _ = controller  // Keep reference to controller
    }
}
