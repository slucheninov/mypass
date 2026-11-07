import XCTest
import MyPassKit
@testable import MyPass

final class NotesEditorCardTests: XCTestCase {
    func testDraftStatusTextFormatsSavedTime() {
        XCTAssertNil(NotesEditorCard.statusText(lastSavedAt: nil))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 13, minute: 5))!
        let text = NotesEditorCard.statusText(lastSavedAt: date, calendar: cal, locale: Locale(identifier: "en_US_POSIX"))
        // Newer ICU puts U+202F (narrow no-break space) before "PM"; normalise it.
        XCTAssertEqual(text?.replacingOccurrences(of: "\u{202F}", with: " "), "Draft saved 1:05 PM")
    }
}
