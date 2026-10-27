import XCTest
import SwiftUI
@testable import MyPass

/// The update banner lives in a native titlebar accessory, so the behaviour worth pinning is
/// the accessory's lifecycle on the window: exactly one while the banner is visible, none when
/// it is not (an empty accessory would keep its height and leave a blank band), nothing left
/// behind on a window the banner moved away from or was torn down on, and no retained window.
@MainActor
final class UpdateBannerAccessoryControllerTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private func makeController() -> UpdateBannerAccessoryController {
        UpdateBannerAccessoryController { AnyView(Text("banner")) }
    }

    func testVisibleInstallsExactlyOneBottomAccessory() {
        let window = makeWindow()
        let controller = makeController()

        controller.update(window: window, isVisible: true)
        controller.update(window: window, isVisible: true)
        controller.update(window: window, isVisible: true)

        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.first?.layoutAttribute, .bottom)
        XCTAssertTrue(controller.isInstalled)
    }

    func testHidingRemovesTheAccessoryAndShowingAgainRestoresOne() {
        let window = makeWindow()
        let controller = makeController()
        controller.update(window: window, isVisible: true)
        let layoutHeightWithBanner = window.contentLayoutRect.height

        controller.update(window: window, isVisible: false)
        controller.update(window: window, isVisible: false)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
        XCTAssertFalse(controller.isInstalled)
        XCTAssertGreaterThan(window.contentLayoutRect.height, layoutHeightWithBanner,
                             "removing the accessory must give the content its height back")

        controller.update(window: window, isVisible: true)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
        XCTAssertEqual(window.contentLayoutRect.height, layoutHeightWithBanner)
    }

    func testMovingToAnotherWindowLeavesNothingOnTheOldOne() {
        let first = makeWindow()
        let second = makeWindow()
        let controller = makeController()

        controller.update(window: first, isVisible: true)
        controller.update(window: second, isVisible: true)

        XCTAssertTrue(first.titlebarAccessoryViewControllers.isEmpty)
        XCTAssertEqual(second.titlebarAccessoryViewControllers.count, 1)
    }

    func testLosingTheWindowOrDetachingRemovesTheAccessory() {
        let window = makeWindow()
        let controller = makeController()

        controller.update(window: window, isVisible: true)
        controller.update(window: nil, isVisible: true)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
        XCTAssertFalse(controller.isInstalled)

        controller.update(window: window, isVisible: true)
        controller.detach()
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)

        // After detach the controller has forgotten the window: a visibility change alone
        // must not reinstall anything.
        controller.update(window: nil, isVisible: true)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
    }

    func testControllerDoesNotRetainItsWindow() {
        weak var weakWindow: NSWindow?
        let controller = makeController()
        autoreleasepool {
            let window = makeWindow()
            weakWindow = window
            controller.update(window: window, isVisible: true)
            window.close()
        }
        XCTAssertNil(weakWindow, "the controller must hold its window weakly")
        // The window is gone; hiding must be a harmless no-op.
        controller.update(window: nil, isVisible: false)
    }
}

/// The SwiftUI side: the modifier must follow the checker's published state, and it must clean
/// up when its view goes away. Uses a real window with a real hosting controller and the real
/// `AppUpdateChecker`; only the release feed is a stub.
@MainActor
final class UpdateBannerAccessoryIntegrationTests: XCTestCase {
    private struct Feed: ReleaseFeed {
        let version: String
        func latestRelease() async throws -> ReleaseInfo {
            ReleaseInfo(version: SemanticVersion(string: version)!, tag: "v\(version)",
                        url: URL(string: "https://example.invalid/release")!)
        }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        suiteName = "UpdateBannerAccessoryIntegrationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// A short fixed spin, used only where the expected outcome is "nothing happens".
    private func spin(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Pumps the main run loop until `condition` holds or `timeout` expires. SwiftUI delivers the
    /// banner state to the anchor in its own update pass, so a positive assertion waits for the
    /// state it asserts instead of guessing an interval. On timeout the caller's assertion fails.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func testAccessoryTracksBannerStateAndIsRemovedWithTheView() async {
        let checker = AppUpdateChecker(feed: Feed(version: "0.4.1"),
                                       currentVersion: SemanticVersion(string: "0.4.0"),
                                       defaults: defaults)
        let session = VaultSession(fileStore: VaultFileStore(directory: directory))
        let root = Color.clear
            .updateBannerAccessory()
            .environmentObject(checker)
            .environmentObject(session)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        // Color.clear has no intrinsic size; without a real frame every layout height is 0.
        window.setContentSize(NSSize(width: 600, height: 400))
        window.orderFront(nil)
        defer { window.close() }

        // Wait for the first layout so the baseline height is real, then give the (negative)
        // "no banner, no accessory" assertion a short fixed window to be violated in.
        waitUntil { window.contentLayoutRect.height > 0 }
        spin()
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty, "no banner, no accessory")
        let bareLayoutHeight = window.contentLayoutRect.height
        XCTAssertGreaterThan(bareLayoutHeight, 0, "the window must have laid out before the baseline is taken")

        await checker.check(manual: true)
        waitUntil {
            window.titlebarAccessoryViewControllers.count == 1
                && window.contentLayoutRect.height < bareLayoutHeight
        }
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
        XCTAssertLessThan(window.contentLayoutRect.height, bareLayoutHeight)

        checker.dismissBanner()
        waitUntil {
            window.titlebarAccessoryViewControllers.isEmpty
                && window.contentLayoutRect.height == bareLayoutHeight
        }
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty, "Later must remove the accessory, not just empty it")
        XCTAssertEqual(window.contentLayoutRect.height, bareLayoutHeight, "no leftover band after dismissal")

        // Tear the SwiftUI content down while the banner is visible: dismantling must remove
        // the accessory from the window.
        let newer = AppUpdateChecker(feed: Feed(version: "0.4.2"),
                                     currentVersion: SemanticVersion(string: "0.4.0"),
                                     defaults: defaults)
        window.contentViewController = NSHostingController(
            rootView: Color.clear.updateBannerAccessory().environmentObject(newer).environmentObject(session))
        await newer.check(manual: true)
        waitUntil { window.titlebarAccessoryViewControllers.count == 1 }
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1, "a newer release brings the banner back")

        window.contentViewController = NSViewController()
        waitUntil { window.titlebarAccessoryViewControllers.isEmpty }
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty, "removing the view must remove its accessory")
    }
}
