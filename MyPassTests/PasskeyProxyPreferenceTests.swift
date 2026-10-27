import XCTest
@testable import MyPass

final class PasskeyProxyPreferenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.mypass.tests.PasskeyProxyPreferenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultValueIsTrue() {
        XCTAssertTrue(PasskeyProxyPreference.defaultValue)
    }

    func testFreshSuiteIsEnabled() {
        XCTAssertTrue(PasskeyProxyPreference.isEnabled(in: defaults))
    }

    func testExplicitFalseStaysFalse() {
        defaults.set(false, forKey: "passkeyProxyEnabled")
        XCTAssertFalse(PasskeyProxyPreference.isEnabled(in: defaults))
    }

    func testExplicitTrueIsTrue() {
        defaults.set(true, forKey: "passkeyProxyEnabled")
        XCTAssertTrue(PasskeyProxyPreference.isEnabled(in: defaults))
    }

    func testSetWritesTheSharedKey() {
        PasskeyProxyPreference.set(false, in: defaults)
        XCTAssertEqual(defaults.object(forKey: "passkeyProxyEnabled") as? Bool, false)
        XCTAssertFalse(PasskeyProxyPreference.isEnabled(in: defaults))
    }
}
