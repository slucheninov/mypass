import XCTest
@testable import MyPass

@MainActor
final class BrowserSettingsActivatorTests: XCTestCase {
    private let suiteName = "BrowserSettingsActivatorTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testRecordRequestedPaneStoresTheRawValue() {
        BrowserSettingsActivator.recordRequestedPane(.security, in: defaults)
        XCTAssertEqual(defaults.string(forKey: "settingsSelectedPane"), "security")
    }

    func testNilPaneLeavesTheStoredSelectionUntouched() {
        defaults.set("browser", forKey: "settingsSelectedPane")
        BrowserSettingsActivator.recordRequestedPane(nil, in: defaults)
        XCTAssertEqual(defaults.string(forKey: "settingsSelectedPane"), "browser")
    }

    func testDefaultRequestedPaneIsBrowser() {
        XCTAssertEqual(BrowserSettingsActivator.defaultPane, .browser)
    }

    func testCheckForUpdatesOpensAbout() {
        XCTAssertEqual(BrowserSettingsActivator.checkForUpdatesPane, .about)
    }

    func testExtensionPairingStillOpensBrowser() {
        XCTAssertEqual(BrowserSettingsActivator.defaultPane, .browser)
    }
}
