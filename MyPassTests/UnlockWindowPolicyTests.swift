import XCTest
@testable import MyPass

final class UnlockWindowPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func testDisallowedWhenNeverUnlockedByDeviceOrPassword() {
        XCTAssertFalse(
            UnlockWindowPolicy.deviceAuthAllowed(
                now: now,
                lastDeviceUnlock: nil,
                lastFullPasswordEntry: nil,
                deviceWindow: .never,
                accountPasswordWindow: .never
            )
        )
    }

    func testAllowedWithinBothWindows() {
        XCTAssertTrue(
            UnlockWindowPolicy.deviceAuthAllowed(
                now: now,
                lastDeviceUnlock: now.addingTimeInterval(-3600),
                lastFullPasswordEntry: now.addingTimeInterval(-86400),
                deviceWindow: .eightHours,
                accountPasswordWindow: .thirtyDays
            )
        )
    }

    func testDisallowedWhenDeviceWindowElapsed() {
        XCTAssertFalse(
            UnlockWindowPolicy.deviceAuthAllowed(
                now: now,
                lastDeviceUnlock: now.addingTimeInterval(-9 * 3600),
                lastFullPasswordEntry: now.addingTimeInterval(-86400),
                deviceWindow: .eightHours,
                accountPasswordWindow: .thirtyDays
            )
        )
    }

    func testDisallowedWhenAccountPasswordWindowElapsed() {
        XCTAssertFalse(
            UnlockWindowPolicy.deviceAuthAllowed(
                now: now,
                lastDeviceUnlock: now.addingTimeInterval(-3600),
                lastFullPasswordEntry: now.addingTimeInterval(-31 * 86400),
                deviceWindow: .eightHours,
                accountPasswordWindow: .thirtyDays
            )
        )
    }

    func testNeverWindowMeansUnlimitedOnceAnEventHasHappened() {
        XCTAssertTrue(
            UnlockWindowPolicy.deviceAuthAllowed(
                now: now,
                lastDeviceUnlock: now.addingTimeInterval(-365 * 86400),
                lastFullPasswordEntry: now.addingTimeInterval(-365 * 86400),
                deviceWindow: .never,
                accountPasswordWindow: .never
            )
        )
    }

    func testExactBoundaryIsAllowed() {
        XCTAssertTrue(
            UnlockWindowPolicy.deviceAuthAllowed(
                now: now,
                lastDeviceUnlock: now.addingTimeInterval(-8 * 3600),
                lastFullPasswordEntry: now.addingTimeInterval(-30 * 86400),
                deviceWindow: .eightHours,
                accountPasswordWindow: .thirtyDays
            )
        )
    }
}
