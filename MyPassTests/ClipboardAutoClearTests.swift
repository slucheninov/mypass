import XCTest
@testable import MyPass

final class FakePasteboard: PasteboardClearing {
    var current: String?

    func currentString() -> String? { current }

    func clearIfStillContains(_ value: String) {
        if current == value {
            current = nil
        }
    }
}

final class ClipboardAutoClearTests: XCTestCase {
    func testClearsWhenPasteboardUnchanged() {
        let pasteboard = FakePasteboard()
        pasteboard.current = "s3cret"
        let clock = FakeClock()

        ClipboardAutoClear.schedule(value: "s3cret", after: 30, pasteboard: pasteboard, clock: clock)
        clock.fireLast()

        XCTAssertNil(pasteboard.current)
    }

    func testDoesNotClearWhenUserCopiedSomethingElseMeanwhile() {
        let pasteboard = FakePasteboard()
        pasteboard.current = "s3cret"
        let clock = FakeClock()

        ClipboardAutoClear.schedule(value: "s3cret", after: 30, pasteboard: pasteboard, clock: clock)
        pasteboard.current = "something the user copied later"
        clock.fireLast()

        XCTAssertEqual(pasteboard.current, "something the user copied later")
    }
}
