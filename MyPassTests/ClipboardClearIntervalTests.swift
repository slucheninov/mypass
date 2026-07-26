import XCTest
@testable import MyPass

final class ClipboardClearIntervalTests: XCTestCase {
    func testReadsStoredSeconds() {
        let defaults = UserDefaults(suiteName: "ClipboardClearIntervalTests")!
        defaults.removePersistentDomain(forName: "ClipboardClearIntervalTests")
        defaults.set(45, forKey: "clipboardClearSeconds")
        XCTAssertEqual(ClipboardClearInterval.seconds(defaults: defaults), 45)
    }

    func testDefaultIs30WhenUnset() {
        let defaults = UserDefaults(suiteName: "ClipboardClearIntervalTests-default")!
        defaults.removePersistentDomain(forName: "ClipboardClearIntervalTests-default")
        XCTAssertEqual(ClipboardClearInterval.seconds(defaults: defaults), 30)
    }
}
