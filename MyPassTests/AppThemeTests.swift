import XCTest
import AppKit
@testable import MyPass

final class AppThemeTests: XCTestCase {
    @MainActor
    override func tearDown() {
        AppTheme.apply(.system)
        super.tearDown()
    }

    func testRawValuesArePersistedNames() {
        XCTAssertEqual(AppTheme.system.rawValue, "system")
        XCTAssertEqual(AppTheme.light.rawValue, "light")
        XCTAssertEqual(AppTheme.dark.rawValue, "dark")
    }

    func testSystemMapsToNilAppearance() {
        XCTAssertNil(AppTheme.system.appearance)
    }

    func testLightMapsToAqua() {
        XCTAssertEqual(AppTheme.light.appearance?.name, .aqua)
    }

    func testDarkMapsToDarkAqua() {
        XCTAssertEqual(AppTheme.dark.appearance?.name, .darkAqua)
    }

    func testUnknownStoredValueFallsBackToSystem() {
        XCTAssertEqual(AppTheme(storedRaw: "sepia"), .system)
        XCTAssertEqual(AppTheme(storedRaw: ""), .system)
        XCTAssertEqual(AppTheme(storedRaw: nil), .system)
        XCTAssertEqual(AppTheme(storedRaw: "dark"), .dark)
    }

    @MainActor
    func testApplySetsAndClearsApplicationAppearance() {
        AppTheme.apply(.dark)
        XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua)
        AppTheme.apply(.system)
        XCTAssertNil(NSApplication.shared.appearance)
    }
}
