import XCTest
@testable import MyPass

final class NotesRevealTests: XCTestCase {
    func testRevealIsPerEntry() {
        let a = UUID(), b = UUID()
        var state = NotesRevealState()
        state.reveal(entryID: a)
        XCTAssertTrue(state.isRevealed(entryID: a))
        XCTAssertFalse(state.isRevealed(entryID: b))
    }

    func testHideClearsReveal() {
        let a = UUID()
        var state = NotesRevealState()
        state.reveal(entryID: a)
        state.hide()
        XCTAssertFalse(state.isRevealed(entryID: a))
    }

    func testRevealingAnotherEntryReplacesTheFirst() {
        let a = UUID(), b = UUID()
        var state = NotesRevealState()
        state.reveal(entryID: a)
        state.reveal(entryID: b)
        XCTAssertFalse(state.isRevealed(entryID: a))
        XCTAssertTrue(state.isRevealed(entryID: b))
    }

    func testEmptyAndWhitespaceNotesAreNeverBlurred() {
        let id = UUID()
        let state = NotesRevealState()
        XCTAssertFalse(NotesProtection.isBlurred(notes: "", state: state, entryID: id))
        XCTAssertFalse(NotesProtection.isBlurred(notes: " \n ", state: state, entryID: id))
    }

    func testNonEmptyNotesBlurredUntilRevealed() {
        let id = UUID()
        var state = NotesRevealState()
        XCTAssertTrue(NotesProtection.isBlurred(notes: "secret", state: state, entryID: id))
        state.reveal(entryID: id)
        XCTAssertFalse(NotesProtection.isBlurred(notes: "secret", state: state, entryID: id))
    }

    func testNavigationStateResetsRevealWhenSelectionChanges() {
        let a = UUID(), b = UUID()
        let nav = NavigationState()
        nav.selectedEntryID = a
        nav.notesReveal.reveal(entryID: a)
        XCTAssertTrue(nav.notesReveal.isRevealed(entryID: a))
        nav.selectedEntryID = b
        XCTAssertFalse(nav.notesReveal.isRevealed(entryID: a))
        XCTAssertFalse(nav.notesReveal.isRevealed(entryID: b))
    }

    func testHideNotesResetsState() {
        let a = UUID()
        let nav = NavigationState()
        nav.selectedEntryID = a
        nav.notesReveal.reveal(entryID: a)
        nav.hideNotes()
        XCTAssertFalse(nav.notesReveal.isRevealed(entryID: a))
    }
}
