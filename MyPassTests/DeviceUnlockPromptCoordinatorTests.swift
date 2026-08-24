import XCTest
@testable import MyPass

final class DeviceUnlockPromptCoordinatorTests: XCTestCase {
    func testAutoPromptIsAllowedTheFirstTime() {
        let coordinator = DeviceUnlockPromptCoordinator()
        XCTAssertTrue(coordinator.requestAutoPrompt())
    }

    func testAutoPromptFiresAtMostOncePerLockedSession() {
        let coordinator = DeviceUnlockPromptCoordinator()
        XCTAssertTrue(coordinator.requestAutoPrompt())
        coordinator.promptFinished()

        // A second onAppear (or the menu bar reopening) must not fire a second
        // automatic prompt for the same locked session.
        XCTAssertFalse(coordinator.requestAutoPrompt())
    }

    func testInFlightPromptSuppressesAnyOtherAutoPrompt() {
        let coordinator = DeviceUnlockPromptCoordinator()
        XCTAssertTrue(coordinator.requestAutoPrompt())

        // Still in flight (promptFinished() never called) — another surface's
        // auto-prompt must not start a second system sheet.
        XCTAssertFalse(coordinator.requestAutoPrompt())
    }

    func testInFlightPromptSuppressesAnExplicitClick() {
        let coordinator = DeviceUnlockPromptCoordinator()
        XCTAssertTrue(coordinator.requestAutoPrompt())

        XCTAssertFalse(coordinator.requestExplicitPrompt())
    }

    func testExplicitClickIsAllowedAfterTheInFlightPromptFinishes() {
        let coordinator = DeviceUnlockPromptCoordinator()
        XCTAssertTrue(coordinator.requestAutoPrompt())
        coordinator.promptFinished()

        // Explicit clicks are a deliberate retry and must always be allowed once
        // nothing is in flight, even though the automatic prompt already fired.
        XCTAssertTrue(coordinator.requestExplicitPrompt())
    }

    func testExplicitClicksCanRepeatAsLongAsEachOneFinishes() {
        let coordinator = DeviceUnlockPromptCoordinator()
        XCTAssertTrue(coordinator.requestExplicitPrompt())
        coordinator.promptFinished()
        XCTAssertTrue(coordinator.requestExplicitPrompt())
        coordinator.promptFinished()
        XCTAssertTrue(coordinator.requestExplicitPrompt())
    }

    func testReLockingAllowsANewAutoPrompt() {
        let coordinator = DeviceUnlockPromptCoordinator()
        XCTAssertTrue(coordinator.requestAutoPrompt())
        coordinator.promptFinished()
        XCTAssertFalse(coordinator.requestAutoPrompt(), "sanity check: still the same locked session")

        coordinator.vaultDidLock()

        XCTAssertTrue(coordinator.requestAutoPrompt(), "a fresh locked session must get its own auto-prompt allowance")
    }
}
