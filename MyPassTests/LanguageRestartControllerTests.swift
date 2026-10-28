import XCTest
@testable import MyPass

@MainActor
final class LanguageRestartControllerTests: XCTestCase {
    private let suiteName = "ExtensionBridgeServiceTests.LanguageRestart"
    private var defaults: UserDefaults!
    private var store: AppLanguageStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = AppLanguageStore(defaults: defaults, domainName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        super.tearDown()
    }

    private final class FakeLauncher: ApplicationLaunching {
        var calls: [URL] = []
        var overrideSeenAtLaunch: AppLanguage?
        var error: Error?
        var onLaunch: (() -> Void)?

        func launchNewInstance(bundleURL: URL, completion: @escaping (Error?) -> Void) {
            calls.append(bundleURL)
            onLaunch?()
            completion(error)
        }
    }

    private struct LaunchError: Error {}

    private func waitForPhase(_ phase: LanguageRestartController.Phase, on controller: LanguageRestartController, timeout: TimeInterval = 2) {
        let expectation = expectation(description: "phase \(phase)")
        Task { @MainActor in
            while controller.phase != phase { await Task.yield() }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: timeout)
    }

    func testRestartNowStoresTheOverrideBeforeLaunching() {
        let launcher = FakeLauncher()
        let store = self.store!
        launcher.onLaunch = { launcher.overrideSeenAtLaunch = store.storedOverride }
        let controller = LanguageRestartController(launcher: launcher, bundleURL: URL(fileURLWithPath: "/Applications/MyPass.app"), resetDelay: 30)
        controller.restartNow(selecting: .ukrainian, store: store)
        XCTAssertEqual(launcher.overrideSeenAtLaunch, .ukrainian)
    }

    func testRestartNowLaunchesTheOwnBundleURL() {
        let launcher = FakeLauncher()
        let url = URL(fileURLWithPath: "/Applications/MyPass.app")
        let controller = LanguageRestartController(launcher: launcher, bundleURL: url, resetDelay: 30)
        controller.restartNow(selecting: .russian, store: store)
        XCTAssertEqual(launcher.calls, [url])
    }

    func testSuccessfulLaunchMovesToRestartingAndResetsAfterTheDelay() {
        let launcher = FakeLauncher()
        let controller = LanguageRestartController(launcher: launcher, bundleURL: URL(fileURLWithPath: "/x/MyPass.app"), resetDelay: 0.5)
        controller.restartNow(selecting: .ukrainian, store: store)
        // A generous delay and wait: on a loaded runner the polling task must still see
        // `.restarting` before the reset timer returns the phase to `.idle`.
        waitForPhase(.restarting, on: controller, timeout: 5)
        waitForPhase(.idle, on: controller, timeout: 5)
        // The stored choice survives the reset so a retry stays possible.
        XCTAssertEqual(store.storedOverride, .ukrainian)
    }

    func testLaunchFailureRequestsManualRestartAndKeepsTheOverride() {
        let launcher = FakeLauncher()
        launcher.error = LaunchError()
        let controller = LanguageRestartController(launcher: launcher, bundleURL: URL(fileURLWithPath: "/x/MyPass.app"), resetDelay: 30)
        controller.restartNow(selecting: .ukrainian, store: store)
        waitForPhase(.manualRestartNeeded, on: controller)
        XCTAssertEqual(store.storedOverride, .ukrainian)
    }

    func testChangingTheLanguageClearsTheManualRestartHint() {
        let launcher = FakeLauncher()
        launcher.error = LaunchError()
        let controller = LanguageRestartController(launcher: launcher, bundleURL: URL(fileURLWithPath: "/x/MyPass.app"), resetDelay: 30)
        controller.restartNow(selecting: .ukrainian, store: store)
        waitForPhase(.manualRestartNeeded, on: controller)

        controller.languageSelectionChanged()

        XCTAssertEqual(controller.phase, .idle)
    }

    func testChangingTheLanguageDoesNotInterruptARestartInProgress() {
        let launcher = FakeLauncher()
        let controller = LanguageRestartController(launcher: launcher, bundleURL: URL(fileURLWithPath: "/x/MyPass.app"), resetDelay: 30)
        controller.restartNow(selecting: .ukrainian, store: store)
        waitForPhase(.restarting, on: controller)

        controller.languageSelectionChanged()

        XCTAssertEqual(controller.phase, .restarting)
    }

    func testRestartNowNeverRequestsTermination() {
        // The controller has no terminate dependency: the old copy exits only through the
        // single-instance guard and QuitFlushCoordinator. The launcher is the only collaborator.
        let launcher = FakeLauncher()
        let controller = LanguageRestartController(launcher: launcher, bundleURL: URL(fileURLWithPath: "/x/MyPass.app"), resetDelay: 30)
        controller.restartNow(selecting: .english, store: store)
        XCTAssertEqual(launcher.calls.count, 1)
    }
}
