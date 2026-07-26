import XCTest
@testable import MyPass

final class ShortcutCodecTests: XCTestCase {
    func testDecodeShiftCommandL() {
        let parsed = ShortcutCodec.decode("shift+command+L")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.displayString, "⇧⌘L")
    }

    func testEncodeRoundTrip() {
        let original = ShortcutCodec.decode("shift+command+L")!
        XCTAssertEqual(ShortcutCodec.encode(original), "shift+command+L")
    }

    func testEmptyStringDecodesToNil() {
        XCTAssertNil(ShortcutCodec.decode(""))
        XCTAssertNil(ShortcutCodec.decode("   "))
    }

    func testDisplayStringForEmptyIsNone() {
        XCTAssertEqual(ShortcutCodec.displayString(forStorage: ""), "None")
    }
}
