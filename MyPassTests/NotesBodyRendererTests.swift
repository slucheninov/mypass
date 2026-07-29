import XCTest
@testable import MyPass

final class NotesBodyRendererTests: XCTestCase {
    func testPreservesLineBreaksBetweenLines() {
        let rendered = NotesBodyRenderer.render("First line\nSecond line")
        XCTAssertEqual(String(rendered.characters), "First line\nSecond line")
    }

    func testStillRendersInlineBoldStyling() {
        let rendered = NotesBodyRenderer.render("Some **bold** text")
        let hasBoldRun = rendered.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        XCTAssertTrue(hasBoldRun)
    }

    func testFallsBackToPlainTextOnParseFailure() {
        let rendered = NotesBodyRenderer.render("")
        XCTAssertEqual(String(rendered.characters), "")
    }
}
