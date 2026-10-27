import XCTest
@testable import MyPass

@MainActor
final class DeviceUnlockPromptCoordinatorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPassDeviceUnlockPromptCoordinatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testExplicitPromptIsAllowedTheFirstTime() {
        let coordinator = DeviceUnlockPromptCoordinator()
        XCTAssertTrue(coordinator.requestExplicitPrompt())
    }

    func testExplicitPromptIsAllowedAfterEveryLock() throws {
        let session = VaultSession(fileStore: VaultFileStore(directory: tempDir))
        let coordinator = DeviceUnlockPromptCoordinator(vaultSession: session)

        for _ in 0..<3 {
            try session.unlock(password: "correct-horse")
            session.lock()
            // Locking neither grants nor forbids anything beyond the explicit gate.
            XCTAssertTrue(coordinator.requestExplicitPrompt())
            coordinator.promptFinished()
        }
    }

    func testInFlightPromptSuppressesASecondExplicitRequest() {
        let coordinator = DeviceUnlockPromptCoordinator()
        XCTAssertTrue(coordinator.requestExplicitPrompt())

        // Still in flight (promptFinished() never called) — another surface must not
        // start a second system sheet.
        XCTAssertFalse(coordinator.requestExplicitPrompt())
    }

    func testExplicitRequestIsAllowedAgainAfterPromptFinished() {
        let coordinator = DeviceUnlockPromptCoordinator()
        XCTAssertTrue(coordinator.requestExplicitPrompt())
        coordinator.promptFinished()

        XCTAssertTrue(coordinator.requestExplicitPrompt())
    }

    func testLockClearsAnInFlightPrompt() {
        let coordinator = DeviceUnlockPromptCoordinator()
        XCTAssertTrue(coordinator.requestExplicitPrompt())

        coordinator.vaultDidLock()

        XCTAssertTrue(coordinator.requestExplicitPrompt())
    }

    // MARK: - Extension unlock request lifetime

    /// The stale-request scenario: the extension's Unlock is noted, the user then unlocks
    /// with the master password instead (nothing consumed the request because device
    /// unlock was unavailable), and presses Lock within the freshness window. The old
    /// request must not survive the unlock and fire a Touch ID sheet after the Lock.
    /// Driven through the real `$state` subscription, not a direct coordinator call.
    func testUnlockingTheVaultDropsAPendingExtensionUnlockRequest() throws {
        let session = VaultSession(fileStore: VaultFileStore(directory: tempDir))
        let coordinator = DeviceUnlockPromptCoordinator(vaultSession: session)

        coordinator.noteExtensionUnlockRequest()
        try session.unlock(password: "correct-horse")
        session.lock()

        XCTAssertFalse(
            coordinator.consumeExtensionUnlockRequest(),
            "a request noted before the vault unlocked must not outlive the unlock"
        )
    }

    /// `$state` can republish `.locked` (a subscriber attaching, a no-op lock); that must
    /// not wipe a request that is still valid, or the window-closed extension Unlock
    /// path would lose its prompt.
    func testALockedRepublishKeepsAPendingExtensionUnlockRequest() throws {
        let session = VaultSession(fileStore: VaultFileStore(directory: tempDir))
        let coordinator = DeviceUnlockPromptCoordinator(vaultSession: session)

        coordinator.noteExtensionUnlockRequest()
        session.lock()

        XCTAssertTrue(coordinator.consumeExtensionUnlockRequest())
    }

    // MARK: - Stale in-flight self-healing

    /// Simulates `DeviceUnlockAuthenticator`'s completion never arriving (the classic
    /// `LAContext`-released-too-early pitfall): a prompt starts, `promptFinished()` is
    /// never called, and the clock moves forward past the staleness threshold.
    func testAnInFlightPromptOlderThanTheThresholdSelfHeals() {
        var clock = Date()
        let coordinator = DeviceUnlockPromptCoordinator(now: { clock })

        XCTAssertTrue(coordinator.requestExplicitPrompt())
        // `promptFinished()` is deliberately never called here.
        clock = clock.addingTimeInterval(DeviceUnlockPromptCoordinator.staleInFlightThreshold + 1)

        XCTAssertTrue(
            coordinator.requestExplicitPrompt(),
            "a stuck in-flight prompt older than the threshold must self-heal, not wedge the explicit gate forever"
        )
    }

    func testAnInFlightPromptYoungerThanTheThresholdStaysBlocked() {
        var clock = Date()
        let coordinator = DeviceUnlockPromptCoordinator(now: { clock })

        XCTAssertTrue(coordinator.requestExplicitPrompt())
        clock = clock.addingTimeInterval(DeviceUnlockPromptCoordinator.staleInFlightThreshold - 1)

        XCTAssertFalse(coordinator.requestExplicitPrompt(), "not stale yet — must still be treated as in flight")
    }

    // MARK: - Extension unlock request memory

    func testNoExtensionRequestMeansNothingToConsume() {
        let coordinator = DeviceUnlockPromptCoordinator()
        // What a plain view appearance sees: no request, so no prompt.
        XCTAssertFalse(coordinator.consumeExtensionUnlockRequest())
    }

    func testExtensionRequestIsConsumedExactlyOnce() {
        let coordinator = DeviceUnlockPromptCoordinator()
        coordinator.noteExtensionUnlockRequest()

        XCTAssertTrue(coordinator.consumeExtensionUnlockRequest())
        XCTAssertFalse(coordinator.consumeExtensionUnlockRequest())
    }

    func testStaleExtensionRequestIsIgnored() {
        var clock = Date()
        let coordinator = DeviceUnlockPromptCoordinator(now: { clock })
        coordinator.noteExtensionUnlockRequest()

        clock = clock.addingTimeInterval(DeviceUnlockPromptCoordinator.extensionRequestFreshness + 1)

        XCTAssertFalse(coordinator.consumeExtensionUnlockRequest())
    }

    func testLockDoesNotCreateAnExtensionRequest() throws {
        let session = VaultSession(fileStore: VaultFileStore(directory: tempDir))
        let coordinator = DeviceUnlockPromptCoordinator(vaultSession: session)

        try session.unlock(password: "correct-horse")
        session.lock()

        XCTAssertFalse(coordinator.consumeExtensionUnlockRequest())
    }
}
