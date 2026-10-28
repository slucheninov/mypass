import XCTest
@testable import MyPass

final class AppLanguageTests: XCTestCase {
    private let suiteName = "ExtensionBridgeServiceTests.AppLanguage"
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

    private var storedArray: [String]? {
        defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] as? [String]
    }

    func testSelectingUkrainianWritesAppleLanguages() {
        store.select(.ukrainian)
        XCTAssertEqual(storedArray, ["uk"])
        XCTAssertEqual(store.storedOverride, .ukrainian)
    }

    func testSelectingSystemDefaultRemovesTheOverride() {
        store.select(.russian)
        XCTAssertEqual(storedArray, ["ru"])
        store.select(.system)
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"])
        XCTAssertEqual(store.storedOverride, .system)
    }

    func testStoredRegionalCodeMapsToItsLanguage() {
        defaults.set(["uk-UA", "en"], forKey: "AppleLanguages")
        XCTAssertEqual(store.storedOverride, .ukrainian)
    }

    func testUnrecognisedOrEmptyOverrideMapsToSystemAndIsNotRewritten() {
        defaults.set(["de"], forKey: "AppleLanguages")
        XCTAssertEqual(store.storedOverride, .system)
        XCTAssertEqual(storedArray, ["de"])

        defaults.set([String](), forKey: "AppleLanguages")
        XCTAssertEqual(store.storedOverride, .system)
        XCTAssertEqual(storedArray, [])
    }

    func testRestartIsPendingOnlyWhenSelectionDiffersFromLaunch() {
        XCTAssertTrue(AppLanguageStore.isRestartPending(launch: .english, current: .ukrainian))
        XCTAssertFalse(AppLanguageStore.isRestartPending(launch: .english, current: .english))
        // Switching back to the launch language clears the pending state.
        XCTAssertFalse(AppLanguageStore.isRestartPending(launch: .ukrainian, current: .ukrainian))
    }

    func testNativeNamesAreNeverTranslated() {
        XCTAssertEqual(AppLanguage.english.nativeName, "English")
        XCTAssertEqual(AppLanguage.ukrainian.nativeName, "Українська")
        XCTAssertEqual(AppLanguage.russian.nativeName, "Русский")
        XCTAssertNil(AppLanguage.system.nativeName)
    }

    func testSystemHasNoCode() {
        XCTAssertNil(AppLanguage.system.code)
        XCTAssertEqual(AppLanguage.english.code, "en")
        XCTAssertEqual(AppLanguage.ukrainian.code, "uk")
        XCTAssertEqual(AppLanguage.russian.code, "ru")
    }
}
